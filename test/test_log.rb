require 'test/unit'
require 'test_config'
require 'roby/event'
require 'roby/task'
require 'roby/log/marshallable'
require 'roby/log/logger'
require 'roby/log/file'
require 'yaml'
require 'stringio'

class TC_Log < Test::Unit::TestCase
    include Roby

    def teardown
	Log::loggers.clear
    end

    def assert_marshallable_wrapper(object)
	w = Marshallable::Wrapper[object]
	assert_nothing_raised { Marshal.dump(w) }
	assert_nothing_raised { YAML.dump(w) }
	w
    end

    def test_marshallable
	generator = EventGenerator.new(true)
	w_generator = assert_marshallable_wrapper(generator)
	generator.on do |event| 
	    w_event = assert_marshallable_wrapper(event)
	    assert_equal(w_generator, w_event.generator)
	end
	generator.call(nil)

	task = Task.new

	w_task = assert_marshallable_wrapper(task)
	w_task_start = assert_marshallable_wrapper(task.event(:start))
	assert_equal(w_task_start.task, w_task)
	task.on(:start) do |event|
	    w_event = assert_marshallable_wrapper(event)
	    assert_equal(w_event.generator, w_task_start)
	    assert_equal(w_event.task, w_task)
	end

	plan = Plan.new
	w_plan = assert_marshallable_wrapper(plan)
	trsc = Transaction.new(plan)
	w_trsc = assert_marshallable_wrapper(trsc)

	array = assert_marshallable_wrapper([1, 2, plan, task])
	assert_equal(1, array[0])
	assert_equal(2, array[1])
	assert_equal(w_plan, array[2])
	assert_equal(w_task, array[3])

	hash = assert_marshallable_wrapper( { 1 => plan, trsc => task } )
	assert_equal(w_plan, hash[1])
	assert_equal(w_task, hash[w_trsc])
    end

    def next_logged_method(data, expected)
	m, args = data.shift, data.shift
	assert_equal(expected, m)
	[m, args]
    end

    def test_filelogger
	task, source, dest = nil
	data = StringIO.open('', 'w') do |io|
	    logger = Log::FileLogger.new(io)
	    Log::loggers << logger

	    task = Class.new(ExecutableTask) do
		event :start, :command => true
		event :stop
		on :start => :stop
	    end.new
	    source = task.event(:start)
	    dest   = task.event(:stop)

	    source.add_signal(dest)
	    source.call
	    source.remove_signal(dest)
	    Log.flush
	    io.string
	end

	assert( data.length > 0 )

	result = StringIO.open(data, 'r') do |io|
	    begin
		result = []
		loop do
		    result << Marshal.load(io)
		end
	    rescue EOFError
	    end

	    result
	end

	assert_equal(16, result.size)
	_, args = next_logged_method(result, :task_initialize)
	assert_equal(task.object_id, args[1].source_id)
	assert_equal(source.object_id, args[2].source_id)
	assert_equal(dest.object_id, args[3].source_id)

	_, args = next_logged_method(result, :added_event_relation)
	assert_equal(source.object_id, args[2].source_id)
	assert_equal(dest.object_id, args[3].source_id)

	_, args = next_logged_method(result, :generator_calling)
	assert_equal(source.object_id, args[1].source_id)
	_, args = next_logged_method(result, :generator_fired)
	assert_equal(source.object_id, args[1].generator.source_id)

	_, args = next_logged_method(result, :generator_signalling)
	assert_equal(source.object_id, args[1].generator.source_id)
	assert_equal(dest.object_id, args[2].source_id)

	_, args = next_logged_method(result[-2, 2], :removed_event_relation)
	assert_equal(source.object_id, args[2].source_id)
	assert_equal(dest.object_id, args[3].source_id)
    end
end

