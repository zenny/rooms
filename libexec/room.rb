#!/usr/bin/env ruby
#
# Copyright (c) 2016 Mark Heily <mark@heily.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
# 
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

# A room on localhost
class Room
  require "json"
  require "pp"
  require 'tempfile'
  require 'net/ssh'
  require 'shellwords'

  require_relative 'log'
  require_relative 'room_uri'
  require_relative 'spec'
  require_relative 'utility'
  require_relative 'tag_index'
  
  attr_reader :name, :mountpoint, :dataset, :dataset_origin, :tags
  
  include RoomUtility
  
  def initialize(name)
    @name = name
    @user = `whoami`.chomp
    @mountpoint = "/room/#{@user}/#{name}"
    parse_options if exist?
    @logger = Room::Log.instance.logger
  end
 
  def Room.build(specfile)
    spec = Room::Spec.new
    spec.load_file(specfile)
    spec.build
    room = Room.new(spec['label'])
    reindex
    return room
  end

  def index
    if @index.nil?
      @index = Room::TagIndex.new(self)
      @index.load_file(@mountpoint)
    end
    @index
  end
  
  def reindex
    index = Room::TagIndex.new(self)
    index.construct
  end
  
  def exist?
    Room.exist?(@name)
  end
  
  def Room.exist?(name)
    File.exist? "/room/#{`whoami`.chomp}/#{name}"
  end
  
  def tags
    # Strangely, this only lists the first snapshot. If you remove '-o name', it lists them all
    #command = "zfs list -H -r -t snapshot -o name #{@dataset}/share"
    command = "ls -1 #{@mountpoint}/share/.zfs/snapshot"
    logger.debug "running: #{command}"
    `#{command}`.chomp.split(/\n/).map { |x| x.sub(/.*@/, '') }
  end
  
  def is_clone?
    @json['template']['uri'] != ''
  end
  
  def has_tag?(name)
    tags.each do |tag|
      return true if tag == name
    end
    return false
  end
  
  def tags_json
    names = tags
    nameset = tags.map do |name|
      { 'name' => name, 'compression' => 'xz', 'format' => 'zfs' }
    end
    
    JSON.pretty_generate({
      'api' => { 'version' => 0 },
      'tags' => nameset
    })
  end
  
  def options_json
    `cat #{mountpoint}/etc/options.json`.chomp
  end
  
  def origin
    @json['remotes']['origin']
  end
  
  def origin=(uri)
    @json['remotes']['origin'] = uri
    save_options
  end
  
  def template_uri=(s)
    @json['template']['uri'] = s
    save_options  
  end
  
  def template_snapshot=(s)
    @json['template']['snapshot'] = s
    save_options  
  end
  
  def uuid=(s)
    @json['uuid'] = s
    save_options  
  end
  
  # Create a ZFS replication stream and save it at [+path+]
  def create_tags_archive(path)
    cmd = [ 'zfs', 'send', '-v' ]
    if @dataset_origin == '-'
      # This room is not a ZFS clone
      if oldest_snapshot == current_snapshot
        cmd << current_snapshot
      else
        cmd << ['-I', oldest_snapshot, current_snapshot]
      end
    else
      raise 'TODO: send incremental based on origin snapshot'
    end
    cmd << [ '>', path]
    cmd.flatten!
    cmd = cmd.join(' ') #FIXME: workaround for weird issue when array is passed
    system(cmd) or raise 'send operation failed'
  end
  
  # The most recent snapshot of the 'share' dataset
  def current_snapshot
    `zfs list -r -H -t snapshot -o name -S creation #{@dataset}/share | head -1`.chomp
  end

  # The oldest snapshot of the 'share' dataset
  def oldest_snapshot
    `zfs list -r -H -t snapshot -o name -S creation #{@dataset}/share | tail -1`.chomp
  end

  # The snapshot immediately prior to [+snapname+]
  def previous_snapshot(snapname)
    prev = nil
    tags.each do |tag|
      if tag == snapname
        return prev
      else
        prev = tag
      end
    end
    raise 'Snapshot not found'
  end
  
  # Run a script inside the room
  def run_script(buf)
    raise ArgumentError unless buf.kind_of? String
    f = Tempfile.new('room-build-script')
    f.puts buf
    f.flush
    path = '/.room-script-tmp'
    system "cat #{f.path} | room #{@name} exec -u root -- dd of=#{path} status=none" or raise 'command failed'
    system "room #{@name} exec -u root -- sh -c 'chmod 755 #{path} && #{path} && rm #{path}'" or raise 'command failed'
    f.close
  end
  
  private
  
  # Load options.json and get some other random info
  def parse_options
    @dataset = `df -h /room/#{@user}/#{name} | tail -1 | awk '{ print \$1 }'`.chomp
    @dataset_origin = `zfs get -Hp -o value origin #{@dataset}/share`.chomp
    @json = JSON.parse options_json
    if File.exist? "#{@mountpoint}/etc/tags.json"
      @tag_index = Room::TagIndex.new(local_path: @mountpoint)
    end
  end  
  
  def save_options
    File.open("#{mountpoint}/etc/options.json", "w") do |f|
      f.puts JSON.pretty_generate(@json)
    end
  end
  
end

