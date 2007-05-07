require 'roby'
require 'roby/log/gui/replay'
app  = Qt::Application.new(ARGV)
main = Replay.setup(ARGV)

if ARGV.empty?
    require File.join(File.dirname(__FILE__), '..', 'run')
    require File.join(File.dirname(__FILE__), '..', 'load')
    Roby.app.setup

    streams = Roby.app.data_streams(Roby.app.log_dir)
    streams.each do |stream|
	main.add_stream(stream)
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
    main.show
    app.exec
rescue
    STDERR.puts $!.full_message
end

