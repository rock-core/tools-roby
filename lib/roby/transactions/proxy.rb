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
                plan.disable_proxying do
                    pp.text "TProxy:"
                    __getobj__.pretty_print(pp)
                end
            else super
            end
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
            plan_status_handlers.clear
            replacement_handlers.clear
        end

        def on_plan_status_change(&handler)
            plan_status_handlers << handler
        end

        def commit_transaction
            super

            replacement_handlers.each do |h|
                __getobj__.on_replacement(&h)
            end
            plan_status_handlers.each do |h|
                __getobj__.on_plan_status_change(&h)
            end
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
	def partition_new_old_relations(enum, include_proxies: true) # :yield:
	    trsc_objects = Hash.new
	    each_relation do |rel|
                trsc_others = Set.new
                send(enum, rel) do |obj|
                    plan_object =
                        if obj.transaction_proxy?
                            next if !include_proxies
                            obj.__getobj__
                        else obj
                        end

                    trsc_objects[plan_object] = obj
                    trsc_others << plan_object
                end

                plan_others = Set.new
                if include_proxies
                    __getobj__.send(enum, rel) do |child|
                        if plan[child, false]
                            plan_others << child
                        end
                    end
                end

                new = (trsc_others - plan_others)
                existing = (trsc_others - new)
		del = (plan_others - trsc_others)

		yield(trsc_objects, rel, new, del, existing)
	    end
	end

	# Commits the modifications of this proxy. It copies the relations of
	# the proxy on the proxied object
        def commit_transaction
            # The relation graph handling is a bit tricky. We resolve the graphs
            # exclusively using self (NOT other) because if 'other' was a new
            # task, it has been already moved to the new plan (and its relation
            # graph resolution is using the new plan's new graphs already)


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
                real_object.unreachable_handlers.each do |cancel, h|
                    if h.copy_on_replace?
                        event.if_unreachable(cancel_at_emission: cancel, on_replace: :copy, &h.block)
                    end
                end
            end
        end

	def commit_transaction
	    super

	    handlers.each { |h| __getobj__.on(h.as_options, &h.block) }
            unreachable_handlers.each do |cancel, h|
                on_replace = if h.copy_on_replace? then :copy
                             else :drop
                             end
                __getobj__.if_unreachable(
                    cancel_at_emission: cancel,
                    on_replace: on_replace,
                    &h.block)
            end
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

            events = Hash.new
            each_event do |trsc_ev|
                plan_ev = object.event(trsc_ev.symbol)
                transaction.setup_and_register_proxy(trsc_ev, plan_ev)
                events[plan_ev] = trsc_ev
            end

            graphs = transaction.each_event_relation_graph.map do |trsc_g|
                [transaction.plan.event_relation_graph_for(trsc_g.class), trsc_g]
            end
            transaction.import_subplan_relations(graphs, events)
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

