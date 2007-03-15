$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'

require 'roby'
require 'roby/log'
require 'flexmock'

class TC_Log < Test::Unit::TestCase
    include Roby::Test

    def teardown
	Log.clear_loggers
    end

    def test_start_stop_logger
	FlexMock.use do |mock|
	    Log.add_logger mock
	    assert(Log.logging?)
	    assert_nothing_raised { Log.start_logging }

	    Log.remove_logger mock
	    assert(!Log.logging?)
	    assert_nothing_raised { Log.stop_logging }
	end
    end

    def test_misc
	FlexMock.use do |mock|
	    mock.should_receive(:splat?).and_return(true)
	    mock.should_receive(:event).with(1, 2)
	    mock.should_receive(:flush)
	    Log.add_logger mock

	    assert(Log.has_logger?(:flush))
	    assert(Log.has_logger?(:event))

	    assert_equal([mock], Log.enum_for(:each_logger, :event).to_a)
	    assert_equal([], Log.enum_for(:each_logger, :bla).to_a)
	end
    end

    def test_message_splat
	FlexMock.use do |mock|
	    mock.should_receive(:splat?).and_return(true).twice
	    mock.should_receive(:splat_event).with(1, 2).once
	    mock.should_receive(:flush).once
	    Log.add_logger mock

	    Log.log(:splat_event) { [1, 2] }
	    Log.flush
	end
    end

    def test_message_nonsplat
	FlexMock.use do |mock|
	    mock.should_receive(:splat?).and_return(false).twice
	    mock.should_receive(:nonsplat_event).with([1, 2]).once
	    mock.should_receive(:flush).once
	    Log.add_logger mock

	    Log.log(:nonsplat_event) { [1, 2] }
	    Log.flush
	end
    end
end

