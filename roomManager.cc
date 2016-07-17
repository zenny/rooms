/*
 * Copyright (c) 2016 Mark Heily <mark@heily.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <locale>
#include <regex>
#include <string>
#include <streambuf>
#include <unordered_set>

extern "C" {
#include <getopt.h>
#include <jail.h>
#include <pwd.h>
#include <sys/param.h>
#include <sys/jail.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <unistd.h>
}

#include "namespaceImport.h"
#include "shell.h"
#include "fileUtil.h"
#include "room.h"
#include "roomManager.h"

extern FILE *logfile;
#include "logger.h"

string RoomManager::getUserRoomDir(uid_t uid) {
	PasswdEntry pwent(uid);
	string login = pwent.getLogin();

	return string(roomDir + "/" + pwent.getLogin());
}

bool RoomManager::isBootstrapComplete(uid_t uid) {
	return FileUtil::checkExists(getUserRoomDir(uid));
}

void RoomManager::bootstrap(uid_t uid) {
	string zpool;

	if (!FileUtil::checkExists(roomDir)) {

		for (;;) {
			cout << "Enter the ZFS pool that rooms will be stored in: ";
			cin >> zpool;
			string errorMsg;
			if (!validateZfsPoolName(zpool, errorMsg)) {
				cout << "Error: " << errorMsg << endl;
				continue;
			}
			if (Shell::executeWithStatus(
					"zpool list " + zpool + " | grep -q " + zpool) != 0) {
				cout << "Error: no such ZFS pool" << endl;
				continue;
			}
			break;
		}

		Shell::execute(
				"zfs create -o canmount=on -o mountpoint=/room " + zpool
						+ "/room");
	} else {
		zpool = getZfsPoolName(roomDir);
	}

	PasswdEntry pwent(uid);
	if (!FileUtil::checkExists(getUserRoomDir(uid))) {
		Shell::execute("zfs create " + zpool + "/room/" + pwent.getLogin());
	}
}

void RoomManager::setup(uid_t uid) {
	if (!isBootstrapComplete(uid)) {
		throw std::runtime_error("bootstrap is required");
	}

	ownerUid = uid;
	PasswdEntry pwent(uid);
	ownerLogin = pwent.getLogin();
	downloadBase();
	createRoomDir();
	zpoolName = getZfsPoolName(roomDir);
}

void RoomManager::createRoomDir() {
	FileUtil::mkdir_idempotent(roomDir, 0700, 0, 0);
}

void RoomManager::downloadBase() {
	if (!FileUtil::checkExists(baseTarball)) {
		cout << "Downloading base.txz..\n";
		string cmd = "fetch -o " + baseTarball + " " + baseUri;
		if (system(cmd.c_str()) != 0) {
			throw std::runtime_error("Download failed");
		}
	}
}

string RoomManager::getZfsPoolName(const string& path) {
	if (!FileUtil::checkExists(path)) {
		throw std::runtime_error("path does not exist: " + path);
	}

	string cmd = "df -h " + path + " | tail -1 | sed 's,/.*,,'";
	return Shell::popen_readline(cmd);
}

bool RoomManager::validateZfsPoolName(const string& name, string& errorMsg) {
	string buf = name;
	std::locale loc("C");

	errorMsg = "";

	if (name.length() == 0) {
		errorMsg = "name cannot be empty";
		return false;
	}
	if (name.length() > 72) {
		errorMsg = "name is too long";
		return false;
	}
	for (std::string::iterator it = buf.begin(); it != buf.end(); ++it) {
		if (*it == '\0') {
			errorMsg = "NUL in name";
			return false;
		}
		if (std::isalnum(*it, loc) || strchr("-_", *it)) {
			// ok
		} else {
			errorMsg = "Illegal character in name: ";
			errorMsg.push_back(*it);
			return false;
		}
	}
	return true;
}

Room RoomManager::getRoomByName(const string& name) {
	return Room(roomDir, name, ownerUid, getUserRoomDataset());
}

void RoomManager::createRoom(const string& name) {
	log_debug("creating room");

	Room room(roomDir, name, ownerUid, getUserRoomDataset());
	room.create(baseTarball);
}

void RoomManager::destroyRoom(const string& name) {
	string cmd;

	Room room(roomDir, name, ownerUid, getUserRoomDataset());
	room.destroy();
}

void RoomManager::listRooms() {
	if (!FileUtil::checkExists(getUserRoomDir(ownerUid))) {
		// FIXME: will never happen b/c bootstrap ensures the directory exists
		std::clog << "No rooms exist. Run 'room create' to create a room."
				<< endl;
	} else {
		Shell::execute("/bin/ls -1 " + getUserRoomDir(ownerUid));
	}
}

string RoomManager::getUserRoomDataset() {
	if (useZFS) {
		return string(zpoolName + "/room/" + ownerLogin);
	} else {
		return "";
	}
}