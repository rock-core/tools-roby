require 'roby'
require 'roby/log/gui/replay'
app  = Qt::Application.new(ARGV)
main = Replay.setup(ARGV)

if ARGV.empty?
    require File.join(File.dirname(__FILE__), '..', 'run')
    require File.join(File.dirname(__FILE__), '..', 'load')
    Roby.app.setup

    sources = Roby.app.data_sources(log_dir)
    sources.each do |source|
	main.add_source(source)
    end
else
    ARGV.each do |file|
	if streams = Roby.app.data_source([file])
	    main.add_stream(streams)
	else
	    STDERR.puts "WARN: unknown file type #{file}"
	end
    end
end

begin
    app.exec
rescue
    STDERR.puts $!.full_message
end

