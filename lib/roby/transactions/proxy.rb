require 'roby/task'
require 'roby/event'
require 'delegate'
require 'forwardable'
require 'utilrb/module/ancestor_p'
require 'utilrb/queue/get'

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

	attr_reader :discovered_relations

	def initialize(object, transaction)
	    @discovered_relations  = Hash.new
	    @transaction = transaction
	    @__getobj__  = object
	end
	attr_reader :transaction
	attr_reader :__getobj__

	alias :== :eql?

	def pretty_print(pp)
	    plan.disable_proxying { super }
	end
	def proxying?; plan && plan.proxying? end

	def discovered?(relation, written)
	    return false if @discovered_relations.empty?

	    if relation
		if written
		    @discovered_relations[relation]
		else
		    @discovered_relations.has_key?(relation)
		end
	    elsif written
		@discovered_relations.values.any? { |v| v }
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
	    @discovered_relations[relation] = mark
	    relation.subsets.each { |rel| do_discover(rel, mark) }

	    Roby::Control.synchronize do
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
	end

	extend ClassExtension

	def relation_discover(other, type, unused = nil) # :nodoc:
	    discover(type, true)
	    other.discover(type, true) if other.kind_of?(Proxy)
	end
	def adding_child_object(other, type, info) # :nodoc:
	    super if defined? super
	    relation_discover(other, type)
	end
	def adding_parent_object(other, type, info) # :nodoc:
	    super if defined? super
	    relation_discover(other, type)
	end
	def removing_child_object(other, type) # :nodoc:
	    super if defined? super
	    relation_discover(other, type)
	end
	def removing_parent_object(other, type) # :nodoc:
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

	# Enumerates the relations that have either been modified in the
	# transaction (if +written+ is true), or read on the transaction proxy
	# (if +written+ is false)
	def each_discovered_relation(written = true)
	    if written
		@discovered_relations.each { |rel, w| yield(rel) if w }
	    else
		@discovered_relations.each { |rel, w| yield(rel) if !w.nil? }
	    end
	end

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
	    each_discovered_relation(true) do |rel|
		trsc_others = send(enum, rel).
		    map do |obj| 
			plan_object = plan.may_unwrap(obj)
			trsc_objects[plan_object] = obj
			plan_object
		    end.to_value_set

		plan_others = __getobj__.send(enum, rel).
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
		new.each do |other|
		    other.add_child_object(real_object, rel, trsc_objects[other][self, rel])
		end
		del.each do |other|
		    other.remove_child_object(real_object, rel)
		end
	    end

	    partition_new_old_relations(:child_objects) do |trsc_objects, rel, new, del|
		new.each do |other|
		    real_object.add_child_object(other, rel, self[trsc_objects[other], rel])
		end
		del.each do |other|
		    real_object.remove_child_object(other, rel)
		end
	    end

	end

	# Discards the transaction by clearing this proxy
	def discard_transaction
	    clear_vertex
	end
    end

    # Proxy for Roby::EventGenerator
    class EventGenerator < Roby::EventGenerator
	include Proxy
	proxy_for Roby::EventGenerator
	
	def_delegator :@__getobj__, :symbol
	def_delegator :@__getobj__, :model
	proxy :can_signal?
	discover_before :on, true, Roby::EventStructure::CausalLink

	def initialize(object, transaction)
	    super(object, transaction)
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
	def has_sibling?(peer)
	    plan.has_sibling?(peer)
	end

	def executable?; false end
    end

    class TaskEventGenerator < Roby::Transactions::EventGenerator
	proxy_for Roby::TaskEventGenerator
	attr_reader :task
	child_plan_object :task

	def initialize(object, transaction)
	    super(object, transaction)
	    @task = transaction.wrap(object.task)
	end
    end

    # Proxy for Roby::Task
    class Task < Roby::Task
	include Proxy
	proxy_for Roby::Task

	def_delegator :@__getobj__, :running?
	def_delegator :@__getobj__, :finished?
	def_delegator :@__getobj__, :pending?
	def_delegator :@__getobj__, :model
	def_delegator :@__getobj__, :arguments
	def_delegator :@__getobj__, :has_event?

	proxy :event
	proxy :each_event
	alias :each_plan_child :each_event
	proxy :fullfills?
	proxy :same_state?

	def executable?; false end

	def history; "" end
	def plan=(new_plan)
	    if new_plan && new_plan.plan != __getobj__.plan
		raise "invalid plan #{new_plan}"
	    end
	    @plan = new_plan
	end

	def instantiate_model_event_relations
	end

	def discard_transaction
	    clear_relations
	end

	def method_missing(m, *args, &block)
	    if m.to_s =~ /^(\w+)!$/ && has_event?($1.to_sym)
		event($1.to_sym).call(*args)
	    else
	        super
	    end
	end

	def_delegator :@__getobj__, :owners
	def_delegator :@__getobj__, :distribute?
	def has_sibling?(peer)
	    plan.has_sibling?(peer)
	end
    end
end

