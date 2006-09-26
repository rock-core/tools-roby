require 'roby/transactions'

class TC_Transactions < Test::Unit::TestCase
    include Roby::Transactions
    def assert_is_proxy_of(object, wrapper, klass)
	assert_instance_of(klass, wrapper)
	assert_equal(object, wrapper.__getobj__)
    end

    def test_proxy_wrap
	real_klass = Class.new do
	    define_method("forbidden") {}
	end

	proxy_klass = Class.new(DelegateClass(real_klass)) do
	    include Proxy

	    proxy_for real_klass
	    forbid_call :forbidden
	end

	obj   = real_klass.new
	proxy = Proxy.wrap(obj)
	assert_is_proxy_of(obj, proxy, proxy_klass)
	assert_same(proxy, Proxy.wrap(obj))

	proxy.discard
	# should allocate a new proxy object
	new_proxy = Proxy.wrap(obj)
	assert_not_same(proxy, new_proxy)

	# test == 
	assert_not_equal(proxy, new_proxy)
	assert_equal(proxy, obj)

	# check that may_wrap returns the object when wrapping cannot be done
	assert_raises(ArgumentError) { Proxy.wrap(10) }
	assert_equal(10, Proxy.may_wrap(10))

	# test forbid_call
	assert_raises(NotImplementedError) { proxy.forbidden }
    end

    def test_proxy_derived
	base_klass = Class.new
	derv_klass = Class.new(base_klass)
	proxy_base_klass = Class.new(DelegateClass(base_klass)) do
	    include Proxy
	    proxy_for base_klass
	end

	proxy_derv_klass = Class.new(DelegateClass(derv_klass)) do
	    include Proxy
	    proxy_for derv_klass
	end

	base_obj = base_klass.new
	assert_is_proxy_of(base_obj, Proxy.wrap(base_obj), proxy_base_klass)
	derv_obj = derv_klass.new
	assert_is_proxy_of(derv_obj, Proxy.wrap(derv_obj), proxy_derv_klass)
    end

    def test_proxy_forward
	task  = Roby::Task.new
	proxy = Proxy.wrap(task)

	assert_is_proxy_of(task, proxy, Task)

	start_event = proxy.event(:start)
	assert_is_proxy_of(task.event(:start), start_event, EventGenerator)

	proxy.event(:stop)
	proxy.event(:success)
	proxy.each_event do |proxy_event|
	    assert_is_proxy_of(task.event(proxy_event.symbol), proxy_event, EventGenerator)
	end
    end
end

