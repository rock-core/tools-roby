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
	    @discovered  = Hash.new
	    @transaction = transaction
	    @__getobj__ = object
	    self.plan = transaction
	end
	attr_reader :transaction
	attr_reader :__getobj__

	# Fix DelegateClass#== so that comparing the same proxy works
	def ==(other)
	    if other.kind_of?(Proxy)
		self.eql?(other)
	    else
		__getobj__ == other
	    end
	end

	def enable_proxying; plan.enable_proxying end
	def disable_proxying
	    plan.disable_proxying 
	    if block_given?
		begin
		    yield
		ensure
		    enable_proxying
		end
	    end
	end
	def pretty_print(pp)
	    disable_proxying { super }
	end
	def proxying?; plan.proxying? end

	def discovered?(relation, written)
	    return false if @discovered.empty?

	    if relation
		if written
		    @discovered[relation]
		else
		    @discovered.has_key?(relation)
		end
	    elsif written
		@discovered.values.any? { |v| v }
	    else
		true
	    end
	end
	def discover(relation, mark)
	    return unless proxying?
	    raise "transaction is freezed" if plan.freezed?

	    if !relation
		__getobj__.each_relation { |o| discover(o, mark) }
		return
	    end

	    while parent = relation.parent
		relation = parent
	    end
	    do_discover(relation, mark)
	end
	def do_discover(relation, mark)
	    return if discovered?(relation, true)

	    transaction.discovered_object(self, relation)
	    @discovered[relation] = mark
	    relation.subsets.each { |rel| do_discover(rel, mark) }

	    # Bypass add_ and remove_ hooks by using the RelationGraph#link
	    # methods directly. This is needed because we don't really
	    # add new relations, but only copy already existing relations
	    # from the real plan to the transaction graph
	    __getobj__.each_parent_object(relation) do |parent|
		wrapper = transaction[parent]
		relation.link(wrapper, self, parent[__getobj__, relation])
	    end
	    __getobj__.each_child_object(relation) do |child|
		wrapper = transaction[child]
		relation.link(self, wrapper, __getobj__[child, relation])
	    end
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

	    def proxy_component(*methods)
		methods.each do |m|
		    class_eval <<-EOD
		    def #{m}(relation) 
			# Discover all tasks that are supposed to be in the
			# component on the real object, and then compute
			# the component on the transaction graph
			__getobj__.#{m}(relation).each do |task|
			    transaction[task].discover(relation, false)
			end
			super
		    end
		    EOD
		end
	    end

	    # call-seq:
	    #	discover_before(method_name, mark, relation)
	    #
	    # Call #discover when +method+ is called on an object. 
	    #
	    # If +relation+ is a relation graph, uses it as the discovered
	    # relation. If it is an integer, get the relation from the nth
	    # argument of the call. If there is no +relation+ argument or if it
	    # nil), discovers all relations the object is part of at the moment
	    # of the call.
	    #
	    # If +mark+ is false, we map the relations on the proxy but we don't 
	    # mark is as discovered. This allows to do read-only operations on 
	    # proxies.
	    def discover_before(m, mark, relation)
		if Roby::RelationGraph === relation || !relation
		    class_eval do
			class_variable_set("@@_#{m}_discovered_relation_", relation)
		    end
		    class_eval <<-EOD
			def #{m}(*args, &block)
			    discover(@@_#{m}_discovered_relation_, #{mark})
			    super
			end
		    EOD
		elsif relation.kind_of?(Integer)
		    class_eval <<-EOD
		    def #{m}(*args, &block)
			discover(args[#{relation}], #{mark})
			super
		    end
		    EOD
		else
		    raise ArgumentError, "invalid value #{relation}"
		end
	    end

	    # +methods+ should not be called on the proxy
	    def forbid_call(*methods)
		methods.each do |m|
		    class_eval <<-EOD
			def #{m}(*args, &block)
			    raise NotImplementedError, "calls to #{m} are forbidden in transactions" 
			end
		    EOD
		end
	    end
	end

	extend ClassExtension

	proxy_component :component
	proxy_component :generated_subgraph
	proxy_component :reverse_generated_subgraph

	def relation_discover(other, type, unused = nil)
	    discover(type, true)
	    other.discover(type, true) if other.kind_of?(Proxy)
	end
	def adding_child_object(other, type, info)
	    super if defined? super
	    relation_discover(other, type)
	end
	def adding_parent_object(other, type, info)
	    super if defined? super
	    relation_discover(other, type)
	end
	def removing_child_object(other, type)
	    super if defined? super
	    relation_discover(other, type)
	end
	def removing_parent_object(other, type)
	    super if defined? super
	    relation_discover(other, type)
	end

	discover_before :child_object?, false, 1
	discover_before :parent_object?, false, 1
	discover_before :related_object?, false, 1
	discover_before :relations, false, nil
	discover_before :each_relation, false, nil
	discover_before :each_child_object, false, 0
	discover_before :each_parent_object, false, 0
	discover_before :clear_relations, true, nil

	def each_discovered_relation(written = true)
	    if written
		@discovered.each { |rel, w| yield(rel) if w }
	    else
		@discovered.each { |rel, w| yield(rel) if !w.nil? }
	    end
	end

	def commit_relations(enum, is_parent)
	    each_discovered_relation(true) do |rel|
		data = Hash.new
		trsc_others = enum_for(enum, rel).
		    map do |obj|
			if is_parent then info = self[obj, rel]
			else info = obj[self, rel]
			end
			unwrapped = plan.may_unwrap(obj)
			data[unwrapped] = info
			unwrapped
		    end.to_value_set

		plan_others = __getobj__.enum_for(enum, rel).
		    to_value_set

		new = (trsc_others - plan_others)
		del = (plan_others - trsc_others)

		if is_parent
		    new.each do |other|
			__getobj__.add_child_object(other, rel, data[other])
		    end
		    del.each do |other|
			__getobj__.remove_child_object(other, rel)
		    end
		else
		    new.each do |other|
			other.add_child_object(__getobj__, rel, data[other])
		    end
		    del.each do |other|
			other.remove_child_object(__getobj__, rel)
		    end
		end
	    end
	end

	# Called when we need to commit modifications to the plan
	# Proxy#commit_transaction commits relation modification. Override in specific proxies if
	# more is needed
	def commit_transaction
	    commit_relations(:each_child_object, true)
	    commit_relations(:each_parent_object, false)
	end

	# Called when we need to discard the modifications. Proxy#commit
	# simply removes all relations
	def discard_transaction
	    clear_vertex
	end
    end

    # Proxy for Roby::EventGenerator
    class EventGenerator < Roby::EventGenerator
	include Proxy
	proxy_for Roby::EventGenerator
	
	def_delegator :@__getobj__, :symbol
	def_delegator :@__getobj__, :controlable?
	def_delegator :@__getobj__, :model
	proxy :can_signal?
	discover_before :on, true, Roby::EventStructure::CausalLink

	forbid_call :call
	forbid_call :emit

	def commit_transaction
	    super
	    handlers.each { |h| __getobj__.on(&h) }
	end
    end

    class TaskEventGenerator < Roby::Transactions::EventGenerator
	proxy_for Roby::TaskEventGenerator
	proxy :task
    end

    # Proxy for Roby::Task
    class Task < Roby::Task
	include Proxy
	proxy_for Roby::Task

	def initialize(*args, &block)
	    super
	    @bound_events = Hash.new
	end

	def_delegator :@__getobj__, :running?
	def_delegator :@__getobj__, :finished?
	def_delegator :@__getobj__, :pending?
	def_delegator :@__getobj__, :model
	def_delegator :@__getobj__, :arguments
	def_delegator :@__getobj__, :has_event?

	proxy :event
	proxy :each_event
	proxy :fullfills?
	proxy :same_state?

	forbid_call :emit
	forbid_call :start!
	forbid_call :failed!
	forbid_call :stop!
	forbid_call :success!
	def to_s; "tProxy(#{__getobj__.to_s})" end
	def history; "" end
	def plan=(new_plan)
	    @plan = new_plan
	    each_event { |ev| ev.executable = executable? }
	end

	def self.forbidden_command
	    raise NotImplementedError, "calling event commands is forbidden in a transaction"
	end

	def discard_transaction
	    clear_relations
	end

	def method_missing(m, *args, &block)
	    if m.to_s =~ /^(\w+)!$/ && __getobj__.has_event?($1) && 
	        __getobj__.model.event_model($1).controlable?
	        raise NotImplementedError, "it is forbidden to call an event command when in a transaction"
	    else
	        super
	    end
	end
    end

    class Task
	def_delegator :@__getobj__, :owners
	def_delegator :@__getobj__, :distribute?
	def has_sibling?(peer)
	    plan.has_sibling?(peer)
	end
    end
    class EventGenerator
	def_delegator :@__getobj__, :owners
	def_delegator :@__getobj__, :distribute?
	def has_sibling?(peer)
	    plan.has_sibling?(peer)
	end
    end
end

