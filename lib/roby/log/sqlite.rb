require 'roby/log'
require 'roby/distributed'
require 'sqlite3'
require 'stringio'

module Roby::Log
    class SQLiteLogger
	attr_reader :db, :insert
	def initialize(filename)
	    @db = SQLite3::Database.new(filename)
	    db.execute("DROP TABLE IF EXISTS events")
	    db.execute("CREATE TABLE events (
		       method TEXT,
		       sec    INTEGER,
		       usec   INTEGER,
		       args   BLOB)")
	    @insert = db.prepare("insert into events values (?, ?, ?, ?)")
	end
	def splat?; false end

	Roby::Log.each_hook do |klass, m|
	    define_method(m) do |args|
		begin
		    time = args[0]
		    args = SQLite3::Blob.new Roby::Distributed.dump(args[1..-1])
		    insert.execute(m.to_s, time.tv_sec, time.tv_usec, args)
		rescue
		    STDERR.puts "failed to dump #{m}#{args}: #{$!.full_message}"
		end
	    end
	end

	def self.replay(filename)
	    db = SQLite3::Database.new(filename)
	    method_name = nil
	    db.execute("select * from events") do |method_name, sec, usec, args|
		time = Time.at(Integer(sec), Integer(usec))
		args = Marshal.load(StringIO.new(args))
		args.unshift time
		yield(method_name.to_sym, args)
	    end
	rescue
	    STDERR.puts "ignoring call to #{method_name}: #{$!.full_message}"
	end
    end
end

