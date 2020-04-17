# frozen_string_literal: true

module Roby
    module PlanReplaceBehaviors
        module Common
            def setup
                super
                @replacement_dependency_graph =
                    flexmock(replacement_plan.task_relation_graph_for(TaskStructure::Dependency))
                @replacement_forwarding_graph =
                    flexmock(replacement_plan.event_relation_graph_for(EventStructure::Forwarding))
            end
        end

        def self.in_plan_context(context, replace_op)
            context.class_eval do
                include Common
                def replacement_plan
                    plan
                end
                define_method :perform_replacement do |**options|
                    replacement_plan.send(replace_op, @replaced_task, @replacing_task, **options)
                end
            end
        end

        def self.in_transaction_context(context, replace_op)
            context.class_eval do
                include Common
                def replacement_plan
                    @transaction
                end
                define_method :perform_replacement do |**options|
                    replacement_plan.send(replace_op, replacement_plan[@replaced_task], replacement_plan[@replacing_task], **options)
                    replacement_plan.commit_transaction
                end
            end
        end

        def self.validation(context)
            context.it "does nothing if the source and target are the same" do
                @replacing_task = @replaced_task
                flexmock(@replaced_task).should_receive(:replace_by).never
                flexmock(@replaced_task).should_receive(:replace_subplan_by).never
                perform_replacement
            end

            context.it "raises ArgumentError if the replacing task is not in the same plan than the receiver" do
                flexmock(@replacing_task).should_receive(:plan).and_return(Plan.new)
                assert_raises(ArgumentError) { perform_replacement }
            end

            context.it "raises ArgumentError if the replaced task is not in the same plan than the receiver" do
                flexmock(@replaced_task).should_receive(:plan).and_return(Plan.new)
                assert_raises(ArgumentError) { perform_replacement }
            end

            context.it "raises ArgumentError if the replaced task is finalized" do
                plan.remove_task(@replaced_task)
                assert_raises(ArgumentError) { perform_replacement }
            end

            context.it "raises ArgumentError if the replacing task is finalized" do
                plan.remove_task(@replacing_task)
                assert_raises(ArgumentError) { perform_replacement }
            end
        end

        def self.replace_task_common(context)
            context.it "calls the replaced hook" do
                flexmock(replacement_plan).should_receive(:replaced)
                    .with(replacement_plan[@replaced_task], replacement_plan[@replacing_task]).once
                perform_replacement
            end

            context.it "does not touch the target's relations" do
                @task.depends_on @replacing_task
                perform_replacement
                refute @task.child_object?(@replaced_task, TaskStructure::Dependency)
                assert @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch filtered out relations" do
                @task.depends_on @replaced_task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_relation(TaskStructure::Dependency))
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch filtered out graphs" do
                @task.depends_on @replaced_task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_graph(@replacement_dependency_graph))
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch filtered out tasks" do
                @task.depends_on @replaced_task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_tasks([replacement_plan[@task]]))
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "raises if the replacing task does not fullfill the replaced task" do
                flexmock(replacement_plan[@replacing_task]).should_receive(:fullfills?)
                    .and_return(false)
                assert_raises(InvalidReplace) do
                    perform_replacement
                end
            end

            context.it "provides a more useful error message if the InvalidReplace error is caused by missing provided models" do
                model = Task.new_submodel(name: "Test")
                @replaced_task.fullfilled_model = [model, [], {}]
                e = assert_raises(InvalidReplace) do
                    perform_replacement
                end
                assert_equal "missing provided models Test", e.message
            end

            context.it "provides a more useful error message if the InvalidReplace error is caused by mismatching arguments" do
                model = Task.new_submodel
                @replaced_task.fullfilled_model = [Task, [], { arg: 10 }]
                @replacing_task.arguments[:arg] = 20
                e = assert_raises(InvalidReplace) do
                    perform_replacement
                end
                assert_equal "argument mismatch for arg", e.message
            end

            context.it "does not touch strong relations" do
                @task.start_event.handle_with @replaced_task
                perform_replacement
                assert @task.child_object?(@replaced_task, TaskStructure::ErrorHandling)
                refute @task.child_object?(@replacing_task, TaskStructure::ErrorHandling)
            end

            context.it "does not touch relations that exist between the replaced task's events" do
                @replaced_task.start_event.forward_to @replaced_task.stop_event
                perform_replacement
                assert @replaced_task.start_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
            end

            context.it "does not touch relations that exist between the replaced and replacing task's events" do
                @replaced_task.start_event.forward_to @replacing_task.stop_event
                perform_replacement
                assert @replaced_task.start_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
            end
        end

        def self.replace_task(context)
            validation(context)

            context.send(:describe, "copy_on_replace: false") do
                PlanReplaceBehaviors.replace_task_common(self)

                it "moves the relations where the replaced task is a child" do
                    @task.depends_on @replaced_task
                    perform_replacement
                    refute @task.child_object?(@replaced_task, TaskStructure::Dependency)
                    assert @task.child_object?(@replacing_task, TaskStructure::Dependency)
                end

                it "moves the relations where the replaced task is a parent" do
                    @replaced_task.depends_on @task
                    perform_replacement
                    refute @replaced_task.child_object?(@task, TaskStructure::Dependency)
                    assert @replacing_task.child_object?(@task, TaskStructure::Dependency)
                end

                it "moves the replaced task's event relations to the target" do
                    other = Roby::Task.new
                    @replaced_task.start_event.forward_to other.start_event
                    other.stop_event.forward_to @replaced_task.stop_event
                    perform_replacement
                    refute @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    assert @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    refute other.stop_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                    assert other.stop_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
                end
            end

            context.send(:describe, "copy_on_replace: true") do
                before do
                    @replacement_dependency_graph.should_receive(copy_on_replace?: true)
                    @replacement_forwarding_graph.should_receive(copy_on_replace?: true)
                end

                PlanReplaceBehaviors.replace_task_common(self)

                it "copies the relations where the replaced task is a child" do
                    @task.depends_on @replaced_task
                    perform_replacement
                    assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                    assert @task.child_object?(@replacing_task, TaskStructure::Dependency)
                end

                it "copies the relations where the replaced task is a parent" do
                    @replaced_task.depends_on @task
                    perform_replacement
                    assert @replaced_task.child_object?(@task, TaskStructure::Dependency)
                    assert @replacing_task.child_object?(@task, TaskStructure::Dependency)
                end

                it "copies the replaced task's event relations to the target" do
                    other = Roby::Task.new
                    @replaced_task.start_event.forward_to other.start_event
                    other.stop_event.forward_to @replaced_task.stop_event
                    perform_replacement
                    assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    assert other.stop_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                    assert @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    assert other.stop_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
                end
            end

            context.it "keeps the replaced task in the plan" do
                perform_replacement
                assert plan.has_task?(@replaced_task)
            end

            context.it "moves the replaced task's mission status" do
                plan.add_mission_task(@replaced_task)
                perform_replacement
                refute @replaced_task.mission?
                refute plan.mission_task?(@replaced_task)
                assert @replacing_task.mission?
                assert plan.mission_task?(@replacing_task)
            end

            context.it "moves the replaced task's permanent status" do
                plan.add_mission_task(@replaced_task)
                perform_replacement
                refute plan.mission_task?(@replaced_task)
                assert plan.mission_task?(@replacing_task)
            end
        end

        def self.replace_common(context)
            context.it "calls the replaced hook" do
                flexmock(replacement_plan).should_receive(:replaced)
                    .with(replacement_plan[@replaced_task], replacement_plan[@replacing_task]).once
                perform_replacement
            end

            context.it "raises if the replacing task does not fullfill the replaced task" do
                flexmock(replacement_plan[@replacing_task]).should_receive(:fullfills?)
                    .and_return(false)
                assert_raises(InvalidReplace) do
                    perform_replacement
                end
            end

            context.it "provides a more useful error message if the InvalidReplace error is caused by missing provided models" do
                model = Task.new_submodel(name: "Test")
                @replaced_task.fullfilled_model = [model, [], {}]
                e = assert_raises(InvalidReplace) do
                    perform_replacement
                end
                assert_equal "missing provided models Test", e.message
            end

            context.it "provides a more useful error message if the InvalidReplace error is caused by mismatching arguments" do
                model = Task.new_submodel
                @replaced_task.fullfilled_model = [Task, [], { arg: 10 }]
                @replacing_task.arguments[:arg] = 20
                e = assert_raises(InvalidReplace) do
                    perform_replacement
                end
                assert_equal "argument mismatch for arg", e.message
            end

            context.it "does not touch filtered out task relations" do
                @task.depends_on @replaced_task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_relation(TaskStructure::Dependency))
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch filtered out task graphs" do
                @task.depends_on @replaced_task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_graph(@replacement_dependency_graph))
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch filtered out parent tasks" do
                @task.depends_on @replaced_task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_tasks([replacement_plan[@task]]))
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch filtered out child tasks" do
                @replacement_dependency_graph.should_receive(weak?: true)
                @replaced_task.depends_on @task
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_tasks([replacement_plan[@task]]))
                assert @replaced_task.child_object?(@task, TaskStructure::Dependency)
                refute @replacing_task.child_object?(@task, TaskStructure::Dependency)
            end

            context.it "does not touch strong task relations" do
                @replacement_dependency_graph.should_receive(strong?: true)
                @task.depends_on @replaced_task
                perform_replacement
                assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                refute @task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "does not touch relations that exist between the replaced task's events" do
                @replaced_task.start_event.forward_to @replaced_task.stop_event
                perform_replacement
                assert @replaced_task.start_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
            end

            context.it "does not touch relations that exist between the replaced and replacing task's events" do
                @replaced_task.start_event.forward_to @replacing_task.stop_event
                perform_replacement
                assert @replaced_task.start_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
            end

            context.it "does not touch the relations where the replaced task is a parent" do
                @replaced_task.depends_on @task
                perform_replacement
                assert @replaced_task.child_object?(@task, TaskStructure::Dependency)
                refute @replaced_task.child_object?(@replacing_task, TaskStructure::Dependency)
            end

            context.it "ignores in edges from free events" do
                (ev = Roby::EventGenerator.new).forward_to @replaced_task.start_event
                perform_replacement
                assert ev.child_object?(@replaced_task.start_event, EventStructure::Forwarding)
                refute ev.child_object?(@replacing_task.start_event, EventStructure::Forwarding)
            end

            context.it "ignores out edges to free events" do
                @replaced_task.start_event
                    .forward_to(ev = Roby::EventGenerator.new)
                perform_replacement
                assert @replaced_task.start_event.child_object?(ev, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(ev, EventStructure::Forwarding)
            end

            context.it "does not touch event relations that point to the replaced task's subplan" do
                @replaced_task.depends_on(intermediate = Roby::Task.new)
                intermediate.depends_on(other = Roby::Task.new)
                @replaced_task.start_event.forward_to other.start_event
                other.stop_event.forward_to @replaced_task.stop_event
                perform_replacement
                assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                assert other.stop_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                refute other.stop_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
            end

            context.it "does not touch event relations that point to the replacing task's subplan" do
                @replacing_task.depends_on(intermediate = Roby::Task.new)
                intermediate.depends_on(other = Roby::Task.new)
                @replaced_task.start_event.forward_to other.start_event
                other.stop_event.forward_to @replaced_task.stop_event
                perform_replacement
                assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                assert other.stop_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                refute other.stop_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
            end

            context.it "does not touch strong event relations" do
                @replacement_forwarding_graph.should_receive(strong?: true)
                other = Roby::Task.new
                @replaced_task.start_event.forward_to other.start_event
                assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                perform_replacement
                assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
            end

            context.it "does not touch ignored event graphs" do
                other = Roby::Task.new
                @replaced_task.start_event.forward_to other.start_event
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_graph(@replacement_forwarding_graph))
                assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
            end

            context.it "does not touch ignored event relations" do
                other = Roby::Task.new
                @replaced_task.start_event.forward_to other.start_event
                perform_replacement(filter: Plan::ReplacementFilter.new.exclude_relation(EventStructure::Forwarding))
                assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                refute @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
            end
        end

        def self.replace(context)
            validation(context)

            context.send(:describe, "copy_on_replace: false") do
                PlanReplaceBehaviors.replace_common(self)

                it "moves the relations where the replaced task is a child" do
                    @task.depends_on @replaced_task
                    perform_replacement
                    refute @task.child_object?(@replaced_task, TaskStructure::Dependency)
                    assert @task.child_object?(@replacing_task, TaskStructure::Dependency)
                end

                it "moves weak relations even if the replaced task is a parent" do
                    @replacement_dependency_graph.should_receive(weak?: true)
                    @replaced_task.depends_on @task
                    perform_replacement
                    refute @replaced_task.child_object?(@task, TaskStructure::Dependency)
                    assert @replacing_task.child_object?(@task, TaskStructure::Dependency)
                end

                it "moves the replaced task's external event relations to the target" do
                    other = Roby::Task.new
                    @replaced_task.start_event.forward_to other.start_event
                    other.stop_event.forward_to @replaced_task.stop_event
                    perform_replacement
                    refute @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    assert @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    refute other.stop_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                    assert other.stop_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
                end
            end

            context.send(:describe, "copy_on_replace: true") do
                before do
                    @replacement_dependency_graph.should_receive(copy_on_replace?: true)
                    @replacement_forwarding_graph.should_receive(copy_on_replace?: true)
                end

                PlanReplaceBehaviors.replace_common(self)

                it "copies the relations where the replaced task is a child" do
                    @task.depends_on @replaced_task
                    perform_replacement
                    assert @task.child_object?(@replaced_task, TaskStructure::Dependency)
                    assert @task.child_object?(@replacing_task, TaskStructure::Dependency)
                end

                it "copies weak relations even if the replaced task is a parent" do
                    @replacement_dependency_graph.should_receive(weak?: true)
                    @replaced_task.depends_on @task
                    perform_replacement
                    assert @replaced_task.child_object?(@task, TaskStructure::Dependency)
                    assert @replacing_task.child_object?(@task, TaskStructure::Dependency)
                end

                it "copies the replaced task's external event relations to the target" do
                    other = Roby::Task.new
                    @replaced_task.start_event.forward_to other.start_event
                    other.stop_event.forward_to @replaced_task.stop_event
                    perform_replacement
                    assert @replaced_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    assert @replacing_task.start_event.child_object?(other.start_event, EventStructure::Forwarding)
                    assert other.stop_event.child_object?(@replaced_task.stop_event, EventStructure::Forwarding)
                    assert other.stop_event.child_object?(@replacing_task.stop_event, EventStructure::Forwarding)
                end
            end

            context.it "keeps the replaced task in the plan" do
                perform_replacement
                assert plan.has_task?(@replaced_task)
            end

            context.it "moves the replaced task's mission status" do
                plan.add_mission_task(@replaced_task)
                perform_replacement
                refute @replaced_task.mission?
                refute plan.mission_task?(@replaced_task)
                assert @replacing_task.mission?
                assert plan.mission_task?(@replacing_task)
            end

            context.it "moves the replaced task's permanent status" do
                plan.add_mission_task(@replaced_task)
                perform_replacement
                refute plan.mission_task?(@replaced_task)
                assert plan.mission_task?(@replacing_task)
            end

            context.it "raises ArgumentError if the replaced task is finalized" do
                plan.remove_task(@replaced_task)
                assert_raises(ArgumentError) { perform_replacement }
            end

            context.it "raises ArgumentError if the replacing task is finalized" do
                plan.remove_task(@replacing_task)
                assert_raises(ArgumentError) { perform_replacement }
            end
        end
    end
end
