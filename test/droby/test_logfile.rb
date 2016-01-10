require 'roby/test/self'
require 'roby/droby/logfile/reader'
require 'roby/droby/logfile/writer'

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
                w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                w.close
                r = Logfile::Reader.open(File.join(tmpdir, 'test-events.log'))
                assert_raises(EOFError) do
                    r.load_one_cycle
                end
            end

            it "loads the plugins registered in the log file" do
                w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'), plugins: ['test'])
                w.close

                flexmock(Roby.app).should_receive(:using).with('test').once
                r = Logfile::Reader.open(File.join(tmpdir, 'test-events.log'))
                assert_raises(EOFError) do
                    r.load_one_cycle
                end
            end

            it "dumps and loads one cycle" do
                w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                w.dump([:cycle_end, 0, 0, [Hash[test: 10]]])
                w.close

                r = Logfile::Reader.open(File.join(tmpdir, 'test-events.log'))
                data = r.load_one_cycle
                assert_equal [:cycle_end, 0, 0, [Hash[test: 10]]], data
            end

            it "raises on creation if it encounters the wrong magic" do
                File.open(dummy_path = File.join(tmpdir, 'dummy'), 'w') do |io|
                    io.write "FGOEIJDOEJIDEOIJ"
                end
                assert_raises(Logfile::InvalidFileError) do
                    Logfile::Reader.open(dummy_path)
                end
            end

            it "raises on creation if the file is outdated" do
                File.open(dummy_path = File.join(tmpdir, 'dummy'), 'w') do |io|
                    io.write(Logfile::MAGIC_CODE)
                    io.write([4].pack("L<"))
                end
                assert_raises(Logfile::InvalidFormatVersion) do
                    Logfile::Reader.open(dummy_path)
                end
            end

            describe "index handling" do
                it "raises if there is no index and rebuild is false" do
                    w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                    w.close
                    r = Logfile::Reader.open(File.join(tmpdir, 'test-events.log'))
                    assert_raises(Logfile::IndexMissing) { r.index(rebuild: false) }
                end

                it "generates a missing index" do
                    w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                    start, stop = Time.at(1, 1), Time.at(1, 2)
                    log_data = [
                        [:cycle_end, start.tv_sec, start.tv_usec, [Hash[start: [start.tv_sec, start.tv_usec]]]],
                        [:cycle_end, stop.tv_sec, stop.tv_usec, [Hash[start: [stop.tv_sec, stop.tv_usec], end: 1]]]]
                    w.dump(log_data[0])
                    w.dump(log_data[1])
                    w.close

                    path = File.join(tmpdir, 'test-events.log')
                    r = Logfile::Reader.open(path)
                    flexmock(Logfile::Index).should_receive(:rebuild).once.pass_thru
                    index = r.index(rebuild: true)
                    assert index.valid_for?(path)
                    assert_equal [start, stop + 1], index.range
                    assert_equal 2, index.cycle_count
                    assert !index.empty?
                end

                it "regenerates an invalid index" do
                    w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                    w.close

                    path = File.join(tmpdir, 'test-events.log')
                    r = Logfile::Reader.open(path)
                    r.rebuild_index
                    flexmock(Logfile::Index).should_receive(:rebuild).once.pass_thru
                    flexmock(Logfile::Index).new_instances.should_receive(:valid_for?).and_return(false, true)
                    index = r.index(rebuild: true)
                end

                it "does not influence the logfile's IO status by rebuilding the index" do
                    path = File.join(tmpdir, 'test-events.log')
                    w = Logfile::Writer.open(path)
                    start, stop = Time.at(1, 1), Time.at(1, 2)
                    log_data = [
                        [:cycle_end, start.tv_sec, start.tv_usec, [Hash[start: [start.tv_sec, start.tv_usec]]]],
                        [:cycle_end, stop.tv_sec, stop.tv_usec, [Hash[start: [stop.tv_sec, stop.tv_usec], end: 1]]]]
                    w.dump(log_data[0])
                    w.dump(log_data[1])
                    w.close

                    r = Logfile::Reader.open(path)
                    original_position = r.tell # Not zero as we read the prologue
                    r.rebuild_index
                    assert !r.eof?
                    assert_equal original_position, r.tell
                end

                it "raises if the index is invalid and rebuild is false" do
                    w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                    w.close

                    path = File.join(tmpdir, 'test-events.log')
                    r = Logfile::Reader.open(path)
                    r.rebuild_index
                    flexmock(Logfile::Index).should_receive(:rebuild).never
                    flexmock(Logfile::Index).new_instances.should_receive(:valid_for?).and_return(false, true)
                    assert_raises(Logfile::IndexInvalid) do
                        r.index(rebuild: false)
                    end
                end
            end

            describe Logfile::Reader do
                describe "#index_path" do
                    it "generates the default index path for the file" do
                        w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
                        w.close
                        r = Logfile::Reader.open(File.join(tmpdir, 'test-events.log'))
                        assert_equal File.join(tmpdir, "test-events.idx"), r.index_path
                    end
                end
            end

            describe Logfile::Writer do
                describe "find_invalid_marshalling_object" do
                    it "finds an invalid instance variable" do
                        obj = Object.new
                        obj.instance_variable_set :@test, (i = Class.new)
                        invalid, e = Logfile::Writer.find_invalid_marshalling_object(obj)
                        assert(invalid =~ /#{i.to_s}/)
                        assert(invalid =~ /@test/)
                    end

                    it "finds an invalid element in an enumerable" do
                        obj = [i = Class.new]
                        invalid, e = Logfile::Writer.find_invalid_marshalling_object(obj)
                        assert(invalid =~ /#{i.to_s}/)
                        assert(invalid =~ /\[\]/)
                    end
                end

                it "warns the user about a cycle that cannot be marshalled" do
                    w = Logfile::Writer.open(File.join(tmpdir, 'test-events.log'))
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
        end
    end
end

