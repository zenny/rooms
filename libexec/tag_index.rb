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

# A data structure containing metadata for all of the tags of a room
class Room
  class TagIndex
    require 'json'
    require 'pp'
    
    require_relative 'tag'
    require_relative 'log'

    def initialize(room)
      @room = room
    end
    
    def load_file(path)
      @local_path = path + '/etc/tags.json'
      logger.debug "loading index from #{@local_path}"
      raise Errno::ENOENT, @local_path unless File.exist?(@local_path)
      buf = File.open(@local_path, 'r').readlines.join
      logger.debug "loaded; buf=#{buf}"
      parse(buf)
    end
    
    def tags
      if @tags.nil?
        @tags = []
        @json['tags'].each do |ent|
          @tags << Room::Tag.new(@room, ent)
        end
      end
      @tags
    end
    
    def tag(name: nil, uuid: nil)
      raise ArgumentError if name && uuid     
      if name
        tags.each { |x| return x if x.name == name }
      elsif uuid
        raise 'todo'
      end
      raise Errno::ENOENT
    end
    
    # Construct an index for a local room
    def construct   
      indexfile = @room.mountpoint + '/etc/tags.json'
      if File.exist?(indexfile)
        logger.debug "skipping; index already exists"
      else
        system "rm -f #{@room.mountpoint}/tags/*"
        result = {'api' => { 'version' => 0 }, 'tags' => []}
        room.tags.each do |tag|
          meta = Room::Tag.from_snapshot(tag, @room)
          result['tags'] << meta
        end
        File.open(indexfile, 'w') { |f| f.puts JSON.pretty_generate(result) }
      end
    end
    
    def parse(json)
      begin
      @json = JSON.parse(json)
      rescue => e
        puts "error in JSON: #{json}"
        raise e
      end
    end

    # @param scp [Net::SCP] open connection to the remote server
    # @param remote_path [String] path to the remote room       
    def connect(scp, remote_path)
      @scp = scp
      @remote_path = remote_path
    end
    
    def fetch
      raise 'not connected' unless @scp
      data = @scp.download!(@remote_path + '/tags.json')
      @json = JSON.parse(data)
    end
  
    def push
      @scp.upload!(@local_path, @remote_path + '/tags.json')
    end
      
    # The names of all tags
    def names
      @json['tags'].map { |ent| ent['name'] }
    end
    
    def to_s
      @json['tags'].pretty_inspect
    end
    
    # Delete a tag from the index.
    # Does not actually touch the ZFS snapshot.
    def delete(name: nil, uuid: nil)
      raise ArgumentError if name && uuid
      raise ArgumentError, 'UUID not implemented' unless name
      new_tags = [@json['tags'].find { |ent| ent['name'] != name }].flatten
      @json['tags'] = new_tags
    end
    
    private
    
    def logger
      Room::Log.instance.logger
    end
  end
end
__END__

def download_tags
  remote_path = "#{@path}/tags.zfs.xz"
  archive = "#{@tmpdir}/tags.zfs.xz"
  
  logger.debug "downloading #{remote_path} to #{archive}"
  f = File.open(archive, 'w')
  @ssh.open_channel do |channel|
    channel.exec("cat #{Shellwords.escape remote_path}") do |ch, success|
      raise 'command failed' unless success
             
      channel.on_data do |ch, data|
        f.write(data)
      end
      
      channel.on_close do |ch, data|
        f.close
      end
    end
  end

  @ssh.loop

  system('unxz', archive) or raise 'unxz failed'
  archive.sub!(/\.xz\z/, '')
  #TODO zfs recv this
  raise archive
  logger.debug 'tag downloaded successfully'
end