# frozen_string_literal: true

require "roby/test/self"
require "roby/droby/logfile/reader"
require "roby/droby/logfile/writer"
require "roby/test/droby_log_helpers"

module Roby
    module DRoby
        describe Logfile do
            attr_reader :tmpdir
            before do
                @tmpdir = Dir.mktmpdir
            end

            after do
                FileUtils.rm_rf tmpdir if tmpdir
            end

            it "can generate and load an empty file" do
                w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                w.close
                r = Logfile::Reader.open(File.join(tmpdir, "test-events.log"))
                assert !r.load_one_cycle
            end

            it "writes the current file format by default" do
                path = File.join(tmpdir, "test-events.log")
                File.open(path, "w") do |io|
                    Logfile.write_header(io)
                end
                File.open(path, "r") do |io|
                    assert_equal Logfile::FORMAT_VERSION, Logfile.guess_version(io)
                end
            end

            it "allows passing a version ID explicitely" do
                path = File.join(tmpdir, "test-events.log")
                File.open(path, "w") do |io|
                    Logfile.write_header(io, version: 0)
                end
                File.open(path, "r") do |io|
                    assert_equal 0, Logfile.guess_version(io)
                end
            end

            it "loads the plugins registered in the log file" do
                w = Logfile::Writer.open(
                    File.join(tmpdir, "test-events.log"), plugins: ["test"]
                )
                w.close

                flexmock(Roby.app).should_receive(:using).with("test").once
                r = Logfile::Reader.open(File.join(tmpdir, "test-events.log"))
                assert !r.load_one_cycle
            end

            it "dumps and loads one cycle" do
                w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                w.dump([:cycle_end, 0, 0, [Hash[test: 10]]])
                w.close

                r = Logfile::Reader.open(File.join(tmpdir, "test-events.log"))
                data = r.load_one_cycle
                assert_equal [:cycle_end, 0, 0, [Hash[test: 10]]], data
            end

            it "raises on creation if it encounters the wrong magic" do
                File.open(dummy_path = File.join(tmpdir, "dummy"), "w") do |io|
                    io.write "FGOEIJDOEJIDEOIJ"
                end
                assert_raises(Logfile::InvalidFileError) do
                    Logfile::Reader.open(dummy_path)
                end
            end

            it "raises on creation if the file is outdated" do
                File.open(dummy_path = File.join(tmpdir, "dummy"), "w") do |io|
                    io.write(Logfile::MAGIC_CODE)
                    io.write([4].pack("L<"))
                end
                assert_raises(Logfile::InvalidFormatVersion) do
                    Logfile::Reader.open(dummy_path)
                end
            end

            describe "index handling" do
                it "raises if there is no index and rebuild is false" do
                    w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                    w.close
                    r = Logfile::Reader.open(File.join(tmpdir, "test-events.log"))
                    assert_raises(Logfile::IndexMissing) { r.index(rebuild: false) }
                end

                it "generates a missing index" do
                    w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                    start = Time.at(1, 1)
                    stop = Time.at(1, 2)
                    log_data = [
                        [:cycle_end, start.tv_sec, start.tv_usec,
                         [{ start: [start.tv_sec, start.tv_usec] }]],
                        [:cycle_end, stop.tv_sec, stop.tv_usec,
                         [{ start: [stop.tv_sec, stop.tv_usec], end: 1 }]]
                    ]
                    w.dump(log_data[0])
                    w.dump(log_data[1])
                    w.close

                    path = File.join(tmpdir, "test-events.log")
                    r = Logfile::Reader.open(path)
                    flexmock(Logfile::Index).should_receive(:rebuild).once.pass_thru
                    messages = capture_log(Logfile, :warn) do
                        index = r.index(rebuild: true)
                        assert index.valid_for?(path)
                        assert_equal [start, stop + 1], index.range
                        assert_equal 2, index.cycle_count
                        assert !index.empty?
                    end
                    assert_equal ["rebuilding index file for #{path}"], messages
                end

                it "regenerates an invalid index" do
                    w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                    w.close

                    path = File.join(tmpdir, "test-events.log")
                    r = Logfile::Reader.open(path)
                    capture_log(Logfile, :warn) { r.rebuild_index }
                    flexmock(Logfile::Index).should_receive(:rebuild).once.pass_thru
                    flexmock(Logfile::Index)
                        .new_instances.should_receive(:valid_for?)
                        .and_return(false, true)
                    messages = capture_log(Logfile, :warn) do
                        r.index(rebuild: true)
                    end
                    assert_equal ["rebuilding index file for #{path}"], messages
                end

                it "does not influence the logfile's IO status by rebuilding the index" do
                    path = File.join(tmpdir, "test-events.log")
                    w = Logfile::Writer.open(path)
                    start = Time.at(1, 1)
                    stop = Time.at(1, 2)
                    log_data = [
                        [:cycle_end, start.tv_sec, start.tv_usec,
                         [{ start: [start.tv_sec, start.tv_usec] }]],
                        [:cycle_end, stop.tv_sec, stop.tv_usec,
                         [{ start: [stop.tv_sec, stop.tv_usec], end: 1 }]]
                    ]
                    w.dump(log_data[0])
                    w.dump(log_data[1])
                    w.close

                    r = Logfile::Reader.open(path)
                    original_position = r.tell # Not zero as we read the prologue
                    messages = capture_log(Logfile, :warn) do
                        r.rebuild_index
                        assert !r.eof?
                        assert_equal original_position, r.tell
                    end
                    assert_equal ["rebuilding index file for #{path}"], messages
                end

                it "raises if the index is invalid and rebuild is false" do
                    w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                    w.close

                    path = File.join(tmpdir, "test-events.log")
                    r = Logfile::Reader.open(path)
                    capture_log(Logfile, :warn) { r.rebuild_index }
                    flexmock(Logfile::Index).should_receive(:rebuild).never
                    flexmock(Logfile::Index)
                        .new_instances.should_receive(:valid_for?)
                        .and_return(false, true)
                    assert_raises(Logfile::IndexInvalid) do
                        r.index(rebuild: false)
                    end
                end
            end

            describe Logfile::Reader do
                describe "#index_path" do
                    it "generates the default index path for the file" do
                        w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                        w.close
                        r = Logfile::Reader.open(File.join(tmpdir, "test-events.log"))
                        assert_equal File.join(tmpdir, "test-events.idx"), r.index_path
                    end
                end
            end

            describe Logfile::Writer do
                describe "find_invalid_marshalling_object" do
                    it "finds an invalid instance variable" do
                        obj = Object.new
                        obj.instance_variable_set :@test, (i = Class.new)
                        invalid, = Logfile::Writer.find_invalid_marshalling_object(obj)
                        assert(invalid =~ /#{i}/)
                        assert(invalid =~ /@test/)
                    end

                    it "finds an invalid element in an enumerable" do
                        obj = [i = Class.new]
                        invalid, = Logfile::Writer.find_invalid_marshalling_object(obj)
                        assert(invalid =~ /#{i}/)
                        assert(invalid =~ /\[\]/)
                    end
                end

                it "warns the user about a cycle that cannot be marshalled" do
                    w = Logfile::Writer.open(File.join(tmpdir, "test-events.log"))
                    klass = Class.new
                    flexmock(Roby::DRoby::Logfile.logger) do |r|
                        r.should_receive(:fatal).with(/#{klass}/).once
                        r.should_receive(:fatal)
                    end
                    assert_raises(TypeError) do
                        w.dump([:cycle_end, 0, 0, [Hash[test: klass]]])
                    end
                end
            end

            describe Logfile::Index do
                describe ".rebuild" do
                    include Test::DRobyLogHelpers

                    it "creates an index that describes the log file" do
                        Timecop.freeze(Time.at(0))
                        path = droby_create_event_log "test.0.log" do
                            10.times do |i|
                                Timecop.freeze(Time.at(i + 1))
                                droby_write_event :test, i
                                droby_flush_cycle
                            end
                        end

                        Logfile::Index.rebuild_file(path, "#{path}.idx")
                        index = Logfile::Index.read("#{path}.idx")
                        assert index.valid_for?(path)
                        assert_equal 11, index.cycle_count
                        assert_equal [Time.at(0), Time.at(10)], index.range

                        File.open(path, "r") do |io|
                            index.each_with_index do |data, i|
                                break if i == 10

                                io.seek data[:pos]
                                events = ::Marshal.load(Logfile.read_one_chunk(io))
                                assert_equal [:test, 1 + i, 0, [i], :cycle_end],
                                             events[0, 5]
                            end
                        end
                    end
                end

                describe ".valid_file?" do
                    include Test::DRobyLogHelpers

                    before do
                        @log_path = droby_create_event_log("test.log") {}
                        @index_path = @log_path + ".idx"
                    end
                    it "returns true if the file exists and is valid" do
                        Logfile::Index.rebuild_file(@log_path, @index_path)
                        assert Logfile::Index.valid_file?(@log_path, @index_path)
                    end
                    it "returns false if the file exists but is not compatible with the log file" do
                        Logfile::Index.rebuild_file(@log_path, @index_path)
                        droby_create_event_log(@log_path) do
                            droby_write_event :test
                        end
                        refute Logfile::Index.valid_file?(@log_path, @index_path)
                    end
                    it "returns false if the file does not exist" do
                        refute Logfile::Index.valid_file?(@log_path, @index_path)
                    end
                end
            end
        end
    end
end
