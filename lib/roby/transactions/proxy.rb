require 'roby/task'
require 'roby/event'
require 'delegate'
require 'forwardable'
require 'utilrb/module/ancestor_p'

# The Transactions module define all tools needed to implement
# the Transaction class
module Roby::Transactions
    # In transactions, we do not manipulate plan objects like Task and EventGenerator directly,
    # but through proxies which make sure that nothing forbidden is done
    #
    # The Proxy module define base functionalities for these proxy objects
    module Proxy
	@@proxy_klass = []
	@@forwarders  = Hash.new

	def to_s; "tProxy(#{__getobj__.to_s})" end

	# Returns the proxy for +object+. Raises ArgumentError if +object+ is
	# not an object which should be wrapped
	def self.proxy_class(object)
	    proxy_class = @@proxy_klass.find { |_, real_klass| object.kind_of?(real_klass) }
	    unless proxy_class
		raise ArgumentError, "no proxy for #{object.class}"
	    end
	    proxy_class[0]
	end

	# Declare that +proxy_klass+ should be used to wrap objects of +real_klass+.
	# Order matters: if more than one wrapping matches, we will use the one
	# defined last.
	def self.proxy_for(proxy_klass, real_klass)
	    @@proxy_klass.unshift [proxy_klass, real_klass]
	    proxy_klass.extend Forwardable
	end

	# Returns a class that forwards every calls to +proxy.__getobj__+
	def self.forwarder(object)
	    klass = object.class
	    @@forwarders[klass] ||= DelegateClass(klass)
	    @@forwarders[klass].new(object)
	end

	def initialize(object, transaction)
	    @distribute  = nil
	    @transaction = transaction
	    @__getobj__  = object
	end

	module ClassExtension
	    def proxy_for(klass); Proxy.proxy_for(self, klass) end

	    def proxy_code(m)
		"return unless proxying?
		args = args.map(&plan.method(:may_unwrap))
		result = if block_given?
			     __getobj__.#{m}(*args) do |*objects| 
				objects.map! { |o| transaction.may_wrap(o) }
				yield(*objects)
			     end
			 else
			     __getobj__.#{m}(*args)
			 end
		transaction.may_wrap(result)"
	    end

	    def proxy(*methods)
		methods.each do |m|
		    class_eval "def #{m}(*args); #{proxy_code(m)} end"
		end
	    end
	end

	attr_reader :transaction
	attr_reader :__getobj__

	alias :== :eql?

	def pretty_print(pp)
            if plan
                plan.disable_proxying { super }
            else
                super
            end
	end
	def proxying?; plan && plan.proxying? end

	# Uses the +enum+ method on this proxy and on the proxied object to get
	# a set of objects related to this one in both the plan and the
	# transaction.
	# 
	# The block is then given a plan_object => transaction_object hash, the
	# relation which is being considered, the set of new relations (the
	# relations that are in the transaction but not in the plan) and the
	# set of deleted relation (relations that are in the plan but not in
	# the transaction)
	def partition_new_old_relations(enum) # :yield:
	    trsc_objects = Hash.new
	    each_relation do |rel|
		trsc_others = send(enum, rel).
		    map do |obj| 
			plan_object = plan.may_unwrap(obj)
			trsc_objects[plan_object] = obj
			plan_object
		    end.to_value_set

		plan_others = __getobj__.send(enum, rel).
		    find_all { |obj| plan[obj, false] }.
		    to_value_set

		new = (trsc_others - plan_others)
		del = (plan_others - trsc_others)

		yield(trsc_objects, rel, new, del)
	    end
	end

	# Commits the modifications of this proxy. It copies the relations of
	# the proxy on the proxied object
	def commit_transaction
	    real_object = __getobj__
	    partition_new_old_relations(:parent_objects) do |trsc_objects, rel, new, del|
		for other in new
		    other.add_child_object(real_object, rel, trsc_objects[other][self, rel])
		end
		for other in del
		    other.remove_child_object(real_object, rel)
		end
	    end

	    partition_new_old_relations(:child_objects) do |trsc_objects, rel, new, del|
		for other in new
		    real_object.add_child_object(other, rel, self[trsc_objects[other], rel])
		end
		for other in del
		    real_object.remove_child_object(other, rel)
		end
	    end

	    super if defined? super
	end

	# Discards the transaction by clearing this proxy
	def discard_transaction
	    clear_vertex
	    super if defined? super
	end
    end

    # Proxy for Roby::EventGenerator
    class EventGenerator < Roby::EventGenerator
	include Proxy
	proxy_for Roby::EventGenerator
	
	def_delegator :@__getobj__, :symbol
	def_delegator :@__getobj__, :model
	proxy :can_signal?

	def initialize(object, transaction)
	    super(object, transaction)
	    @unreachable_handlers = []
	    if object.controlable?
		self.command = method(:emit)
	    end
	end

	def commit_transaction
	    super
	    handlers.each { |h| __getobj__.on(&h) }
	end

	def_delegator :@__getobj__, :owners
	def_delegator :@__getobj__, :distribute?
	def has_sibling?(peer); plan.has_sibling?(peer) end

	def executable?; false end
	def unreachable!; end
    end

    # Transaction proxy for Roby::TaskEventGenerator
    class TaskEventGenerator < Roby::Transactions::EventGenerator
	proxy_for Roby::TaskEventGenerator

        # The transaction proxy which represents the event generator's real
        # task
	attr_reader :task
	child_plan_object :task

        # Create a new proxy representing +object+ in +transaction+
	def initialize(object, transaction)
	    super(object, transaction)
	    @task = transaction.wrap(object.task)
	end

        # Task event generators do not have siblings on remote plan managers.
        # They are always referenced by their name and task.
	def has_sibling?(peer); false end
    end

    # Transaction proxy for Roby::Task
    class Task < Roby::Task
	include Proxy
	proxy_for Roby::Task

	def_delegator :@__getobj__, :running?
	def_delegator :@__getobj__, :finished?
	def_delegator :@__getobj__, :pending?
	def_delegator :@__getobj__, :model
	def_delegator :@__getobj__, :has_event?

	def_delegator :@__getobj__, :pending?
	def_delegator :@__getobj__, :running?
	def_delegator :@__getobj__, :success?
	def_delegator :@__getobj__, :failed?
	def_delegator :@__getobj__, :finished?

	proxy :event
	proxy :each_event
	alias :each_plan_child :each_event
	proxy :fullfills?
	proxy :same_state?

        def kind_of?(klass)
            super || __getobj__.kind_of?(klass)
        end

        # Create a new proxy representing +object+ in +transaction+
	def initialize(object, transaction)
	    super(object, transaction)

	    @arguments = Roby::TaskArguments.new(self)
	    object.arguments.each do |key, value|
		if value.kind_of?(Roby::PlanObject)
		    arguments.update!(key, transaction[value])
		else
		    arguments.update!(key, value)
		end
	    end
	end

        # There is no bound_events map in task proxies. The proxy instead
        # enumerates the real task's events and create proxies when needed.
        #
        # #bound_events is not part of the public API anyways
	def bound_events; {} end

	def instantiate_model_event_relations # :nodoc:
	end
       
        # Transaction proxies are never executable
	def executable?; false end

        # Transaction proxies do not have history
	def history; "" end
	def plan=(new_plan) # :nodoc:
	    if new_plan 
                if new_plan.plan != __getobj__.plan
                    raise "invalid plan #{new_plan}"
                elsif !new_plan.kind_of?(Roby::Transaction)
                    raise "trying to insert a transaction proxy in something else than a transaction (#{new_plan})"
                end
            end
	    @plan = new_plan
	end

        # Perform the operations needed for the commit to be successful.  In
        # practice, it updates the task arguments as needed.
	def commit_transaction
	    super
	    
	    # Update the task arguments. The original
	    # Roby::Task#commit_transaction has already translated the proxy
	    # objects into real objects
	    arguments.each do |key, value|
		__getobj__.arguments.update!(key, value)
	    end
	end

        # Perform the operations needed for the transaction to be discarded.
	def discard_transaction
	    clear_relations
	end

	def method_missing(m, *args, &block) # :nodoc:
	    if m.to_s =~ /^(\w+)!$/ && has_event?($1.to_sym)
		event($1.to_sym).call(*args)
	    elsif !Roby::Task.method_defined?(m)
		__getobj__.send(m, *args, &block)
	    else
		super
	    end
	end

	def_delegator :@__getobj__, :owners
	def_delegator :@__getobj__, :distribute?

        # True if +peer+ has a representation of this object
	def has_sibling?(peer)
	    plan.has_sibling?(peer)
	end
    end
end

