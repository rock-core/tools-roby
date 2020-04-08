# frozen_string_literal: true

require "roby"
require "fileutils"
Roby.app.load_base_config
app = Roby.app

unless (name = ARGV.shift)
    STDERR.puts "calling 'results' with no arguments does nothing anymore"
    exit 0
end

begin
    src = Roby.app.log_current_dir
rescue ArgumentError
    STDERR.puts "no current log directory, nothing to do"
    exit 0
end

dest = Roby::Application.unique_dirname(Roby.app.log_base_dir, name, Roby.app.log_read_time_tag)
FileUtils.mv src, dest
STDERR.puts "moved current log directory #{src}"
STDERR.puts "  to #{dest}"
FileUtils.rm_f File.join(Roby.app.log_base_dir, "current")
FileUtils.ln_sf dest, File.join(Roby.app.log_base_dir, "current")
STDERR.puts "the symbolic link logs/current has been updated to the new location"
