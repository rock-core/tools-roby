TOP_SRC_DIR = File.expand_path( File.join(File.dirname(__FILE__), '..') )
$LOAD_PATH.unshift TOP_SRC_DIR
$LOAD_PATH.unshift File.join(TOP_SRC_DIR, 'test')
require 'test_config'
require 'genom/runner'
require 'roby/adapters/genom'

include Roby

GC.disable
::Genom::Runner.h2 do |env|
    ::Genom.connect do
        Roby::Genom::GenomModule('mockup')
        env.start_modules('mockup')

        task = Roby::Genom::Mockup.start
        task.start!

        while !task.running?
            $stderr.puts "waiting for task to start"
            Roby.process_events
        end

        task.activity.abort.wait
        while !task.finished?
            $stderr.puts "waiting for task to end"
            Roby.process_events
        end
    end
end

