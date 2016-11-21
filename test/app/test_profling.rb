require 'roby/test/self'
require 'roby/app/profiling'

module Roby
    module App
        describe Profiling do
            attr_reader :profiling
            before do
                app = Application.new
                app.log_dir = make_tmpdir
                @profiling = Profiling.new(app)
                register_plan(app.plan)
            end

            def mock_context
                FlexMock.use(StackProf) do |stackprof_mock|
                    FlexMock.use(profiling) do |profiling_mock|
                        yield(profiling_mock, stackprof_mock)
                    end
                end
            end

            describe "#start" do
                it "starts the profiling" do
                    flexmock(StackProf).should_receive(:start).once
                    profiling.start
                end
                it "passes the mode, interval and raw arguments to StackProf" do
                    mode, interval, raw = flexmock, flexmock, flexmock
                    flexmock(StackProf).should_receive(:start).with(mode: mode, interval: interval, raw: raw).once
                    profiling.start(mode: mode, interval: interval, raw: raw)
                end
                it "saves after the specified number of cycles" do
                    mock_context do |profiling, stackprof|
                        stackprof.should_receive(:start).once
                        profiling.start(cycles: 5)
                    end
                    2.times do
                        mock_context do |profiling, stackprof|
                            profiling.should_receive(:save).never
                            4.times { process_events }
                        end
                        mock_context do |profiling, stackprof|
                            stackprof.should_receive(:stop).once.globally.ordered
                            profiling.should_receive(:save).once.globally.ordered
                            stackprof.should_receive(:start).once.globally.ordered
                            process_events
                        end
                    end
                end
                it "stops and saves after the specified number of cycles if one_shot is set" do
                    mock_context do |profiling, stackprof|
                        stackprof.should_receive(:start).once
                        profiling.start(one_shot: true, cycles: 5)
                    end
                    mock_context do |profiling, stackprof|
                        profiling.should_receive(:save).never
                        stackprof.should_receive(:stop).never
                        4.times { process_events }
                    end
                    mock_context do |profiling, stackprof|
                        stackprof.should_receive(:stop).once.ordered
                        profiling.should_receive(:save).once.ordered
                        process_events
                    end
                    mock_context do |profiling, stackprof|
                        profiling.should_receive(:save).never
                        stackprof.should_receive(:stop).never
                        5.times { process_events }
                    end
                end
                it "does only one cycle if one_shot is set but no cycles are given" do
                    mock_context do |profiling, stackprof|
                        stackprof.should_receive(:start).once
                        profiling.start(one_shot: true)
                    end
                    mock_context do |profiling, stackprof|
                        stackprof.should_receive(:stop).once.ordered
                        profiling.should_receive(:save).once.ordered
                        stackprof.should_receive(:start).never
                        process_events
                    end
                    mock_context do |profiling, stackprof|
                        profiling.should_receive(:save).never
                        stackprof.should_receive(:stop).never
                        5.times { process_events }
                    end
                end
                it "defaults to the 'stackprof' subdirectory of log_dir to save the path" do
                    flexmock(profiling.app).should_receive(:log_dir).and_return('/path/to')
                    flexmock(StackProf).should_receive(:start).once
                    profiling.start
                    assert_equal '/path/to/stackprof', profiling.path
                end
            end
            describe "#stop" do
                it "stops profiling" do
                    flexmock(StackProf).should_receive(:start).once
                    flexmock(StackProf).should_receive(:stop).once
                    profiling.start
                    profiling.stop
                end
                it "disables the one_shot handler" do
                    flexmock(StackProf).should_receive(:start).once
                    flexmock(StackProf).should_receive(:stop).once
                    profiling.start(one_shot: true)
                    profiling.stop
                    flexmock(profiling).should_receive(:stop).never
                    process_events
                end
            end
            describe "#save" do
                before do
                    flexmock(StackProf).should_receive(:results).and_return(Hash.new).by_default
                end
                it "defaults to #default_path for the file path" do
                    flexmock(profiling).should_receive(:default_path).
                        and_return('/path/to/dump/file')
                    flexmock(FileUtils).should_receive(:mkdir_p).
                        with('/path/to/dump').once
                    flexmock(File).should_receive(:open).
                        with('/path/to/dump/file', any, Proc).
                        once
                    profiling.save
                end
                it "allows specifying another file path" do
                    flexmock(FileUtils).should_receive(:mkdir_p).
                        with('/path/to/dump').once
                    flexmock(File).should_receive(:open).
                        with('/path/to/dump/file', any, Proc).
                        once
                    profiling.save(path: '/path/to/dump/file')
                end
                it "expands a %s in the path to the results' mode" do
                    flexmock(StackProf).should_receive(:results).
                        and_return(mode: :cpu)
                    flexmock(FileUtils).should_receive(:mkdir_p).
                        with('/path/to/cpu').once
                    flexmock(File).should_receive(:open).
                        with('/path/to/cpu/file', any, Proc).
                        once
                    profiling.save(path: '/path/to/%s/file')
                end
            end
        end
    end
end

