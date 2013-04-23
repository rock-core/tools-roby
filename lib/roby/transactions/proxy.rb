require 'roby/task'
require 'roby/event'
require 'delegate'
require 'forwardable'
require 'utilrb/module/ancestor_p'
require 'roby/transactions'

class Module
    # Declare that +proxy_klass+ should be used to wrap objects of +real_klass+.
    # Order matters: if more than one wrapping matches, we will use the one
    # defined last.
    def proxy_for(real_klass)
        Roby::Transaction::Proxying.define_proxying_module(self, real_klass)
    end
end


module Roby
    # In transactions, we do not manipulate plan objects like Task and EventGenerator directly,
    # but through proxies which make sure that nothing forbidden is done
    #
    # The Proxy module define base functionalities for these proxy objects
    module Transaction::Proxying
        @@proxying_modules  = Hash.new
        @@forwarder_modules = Hash.new

	def to_s; "tProxy(#{__getobj__.to_s})" end

        def self.proxying_modules
            @@proxying_modules
        end

        def self.define_proxying_module(proxying_module, mod)
            @@proxying_modules[mod] = [proxying_module, false]
            nil
        end

        # Returns the proxying module for +object+. Raises ArgumentError if
        # +object+ is not an object which should be wrapped
	def self.proxying_module_for(klass)
	    proxying_module = @@proxying_modules[klass]
            if !proxying_module
                proxying_module = [Module.new, false]
                @@proxying_modules[klass] = proxying_module
            end

            if !proxying_module[1]
                result = proxying_module[0]
                result.include Transaction::Proxying
                klass.ancestors.each do |ancestor|
                    if ancestor != klass
                        if mod_proxy = @@proxying_modules[ancestor]
                            result.include mod_proxy[0]
                        end
                    end
                end
                proxying_module[1] = true
            end

	    proxying_module[0]
	end

        def self.create_forwarder_module(mod)
            result = Module.new do
                attr_accessor :__getobj__
                def transaction_proxy?; true end
                for name in mod.instance_methods(false)
                    next if name =~ /^__.*__$/
                    next if name == :object_id
                    class_eval <<-EOD, __FILE__, __LINE__+1
                    def #{name}(*args, &block)
                        __getobj__.send("#{name}", *args, &block)
                    end
                    EOD
                end 
            end

            @@forwarder_modules[mod] = result
        end

        # Returns a module that, when used to extend an object, will forward all
        # the calls to the object's @__getobj__
	def self.forwarder_module_for(klass)
            if forwarder_module = @@forwarder_modules[klass]
                return forwarder_module
            end

            result = create_forwarder_module(klass)
            klass.ancestors.each do |ancestor|
                next if ancestor == klass
                if forwarder_module = @@forwarder_modules[ancestor]
                    result.include forwarder_module
                else
                    result.include(create_forwarder_module(ancestor))
                end
            end
            result
	end

	attr_reader :__getobj__

        def transaction_proxy?; true end

	def setup_proxy(object, plan)
	    @__getobj__  = object
	end

	alias :== :eql?

	def pretty_print(pp)
            if plan
                plan.disable_proxying { super }
            else
                super
            end
	end

        def commit_transaction
            super if defined? super
        end

	def proxying?; plan && plan.proxying? end

        # True if +peer+ has a representation of this object
        #
        # In the case of transaction proxies, we know they have siblings if the
        # transaction is present on the other peer.
	def has_sibling?(peer)
	    plan.has_sibling?(peer)
	end
    end

    module PlanService::Proxying
        proxy_for PlanService

        def task=(new_task)
            @task = new_task
        end

        def setup_proxy(object, plan)
            super
            finalization_handlers.clear
            event_handlers.clear
        end

        def commit_transaction
            super

            event_handlers.each do |event, handlers|
                handlers.each do |h|
                    __getobj__.on(event, &h)
                end
            end
            finalization_handlers.each do |h|
                __getobj__.when_finalized(&h)
            end
        end
    end

    module PlanObject::Proxying
        proxy_for PlanObject

        def setup_proxy(object, plan)
            super(object, plan)
            @finalization_handlers.clear
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
                existing = (trsc_others - new)
		del = (plan_others - trsc_others)

		yield(trsc_objects, rel, new, del, existing)
	    end
	end

	# Discards the transaction by clearing this proxy
	def discard_transaction
	    clear_vertex
	    super if defined? super
	end

	# Commits the modifications of this proxy. It copies the relations of
	# the proxy on the proxied object
        def commit_transaction
	    real_object = __getobj__
	    partition_new_old_relations(:parent_objects) do |trsc_objects, rel, new, del, existing|
		for other in new
		    other.add_child_object(real_object, rel, trsc_objects[other][self, rel])
		end
		for other in del
		    other.remove_child_object(real_object, rel)
		end
                for other in existing
                    other[real_object, rel] = trsc_objects[other][self, rel]
                end
	    end

	    partition_new_old_relations(:child_objects) do |trsc_objects, rel, new, del, existing|
		for other in new
		    real_object.add_child_object(other, rel, self[trsc_objects[other], rel])
		end
		for other in del
		    real_object.remove_child_object(other, rel)
		end
                for other in existing
                    real_object[other, rel] = self[trsc_objects[other], rel]
                end
	    end

            super

            if @executable != __getobj__.instance_variable_get(:@executable)
                __getobj__.executable = @executable
            end

            finalization_handlers.each do |handler|
                __getobj__.when_finalized(handler.as_options, &handler.block)
            end
        end

        def initialize_replacement(object)
            super

            # Apply recursively all finalization handlers of this (proxied)
            # object to the object event
            #
            # We have to look at all levels as, in transactions, the "handlers"
            # set only contains new handlers
            real_object = self
            while real_object.transaction_proxy?
                real_object = real_object.__getobj__
                real_object.finalization_handlers.each do |h|
                    if h.copy_on_replace?
                        object.when_finalized(h.as_options, &h.block)
                    end
                end
            end
        end
    end

    module EventGenerator::Proxying
	proxy_for EventGenerator
	
	def setup_proxy(object, plan)
	    super(object, plan)
            @handlers.clear
	    @unreachable_handlers.clear
	    if object.controlable?
		@command = method(:emit)
	    end
	end

        def initialize_replacement(event)
            super

            # Apply recursively all event handlers of this (proxied) event to
            # the new event
            #
            # We have to look at all levels as, in transactions, the "handlers"
            # set only contains new event handlers
            real_object = self
            while real_object.transaction_proxy?
                real_object = real_object.__getobj__
                real_object.handlers.each do |h|
                    if h.copy_on_replace?
                        event.on(h.as_options, &h.block)
                    end
                end
            end
        end

	def commit_transaction
	    super

	    handlers.each { |h| __getobj__.on(h.as_options, &h.block) }
            unreachable_handlers.each { |cancel, h| __getobj__.if_unreachable(cancel, &h) }
	end
    end

    # Transaction proxy for Roby::TaskEventGenerator
    module TaskEventGenerator::Proxying
	proxy_for TaskEventGenerator

        # Task event generators do not have siblings on remote plan managers.
        # They are always referenced by their name and task.
	def has_sibling?(peer); false end
    end

    # Transaction proxy for Roby::Task
    module Task::Proxying
	proxy_for Task

	def to_s; "tProxy(#{__getobj__.name})#{arguments}" end

        # Create a new proxy representing +object+ in +transaction+
	def setup_proxy(object, transaction)
	    super(object, transaction)

            @poll_handlers.clear
            @execute_handlers.clear

	    @arguments = Roby::TaskArguments.new(self)
	    object.arguments.each do |key, value|
		if value.kind_of?(Roby::PlanObject)
		    arguments.update!(key, transaction[value])
		else
		    arguments.update!(key, value)
		end
	    end

            each_event do |ev|
                transaction.register_proxy(ev, object.event(ev.symbol))
            end
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

            execute_handlers.each do |h|
                __getobj__.execute(h.as_options, &h.block)
            end
            poll_handlers.each do |h|
                __getobj__.poll(h.as_options, &h.block)
            end

            __getobj__.abstract = self.abstract?
            if @fullfilled_model
                __getobj__.fullfilled_model = @fullfilled_model.dup
            end
            __getobj__.do_not_reuse if !@reusable
	end

        # Perform the operations needed for the transaction to be discarded.
	def discard_transaction
	    clear_relations
	end

        def initialize_replacement(task)
            super

            # Apply recursively all event handlers of this (proxied) event to
            # the new event
            #
            # We have to look at all levels as, in transactions, the "handlers"
            # set only contains new event handlers
            real_object = self
            while real_object.transaction_proxy?
                real_object = real_object.__getobj__
                real_object.execute_handlers.each do |h|
                    if h.copy_on_replace?
                        task.execute(h.as_options, &h.block)
                    end
                end
                real_object.poll_handlers.each do |h|
                    if h.copy_on_replace?
                        task.poll(h.as_options, &h.block)
                    end
                end
            end
        end
    end
end

