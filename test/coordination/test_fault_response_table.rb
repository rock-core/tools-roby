# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

describe Roby::Coordination::FaultResponseTable do
    it "is triggered whenever an exception reaches toplevel" do
        fault_handler = nil
        fault_table = Roby::Coordination::FaultResponseTable.new_submodel do
            fault_handler = on_fault with_origin(Roby::Task.stop_event) do
                locate_on_origin
            end
        end
        plan.use_fault_response_table fault_table
        begin
            mission, child = prepare_plan missions: 1, add: 1,
                                          model: Roby::Tasks::Simple
            mission.depends_on child, role: "name"

            events = expect_execution do
                mission.start!
                child.start!
                child.stop!
            end.to do
                emit find_tasks(Roby::Coordination::FaultHandlingTask).start_event
            end

            repair_task = events.first.task
            repairs = child.find_all_matching_repair_tasks(child.failed_event.last)
            assert_equal [repair_task], repairs
            assert_equal fault_handler, repair_task.fault_handler
        ensure
            plan.remove_fault_response_table fault_table
        end
    end

    it "can be attached to a specific task instance" do
        fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel do
            argument :arg
        end
        task = Roby::Tasks::Simple.new
        task.use_fault_response_table fault_table_m, arg: 20
        plan.add(task)
        execute { task.start! }
        assert_equal 1, plan.active_fault_response_tables.size
        table = plan.active_fault_response_tables.first
        assert_kind_of fault_table_m, table
        assert_equal Hash[arg: 20], table.arguments
        execute { task.stop! }
        assert plan.active_fault_response_tables.empty?
    end

    describe "adding fault tables in transactions" do
        it "can be added in a transaction" do
            fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_table_m.argument :arg
            flexmock(plan).should_receive(:use_fault_response_table).with(fault_table_m, arg: 10).once
            plan.in_transaction do |trsc|
                trsc.use_fault_response_table fault_table_m, arg: 10
                trsc.commit_transaction
            end
        end
        it "is not added if the transaction is discarded" do
            fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_table_m.argument :arg
            flexmock(plan).should_receive(:use_fault_response_table).never
            plan.in_transaction do |trsc|
                trsc.use_fault_response_table fault_table_m, arg: 10
                trsc.discard_transaction
            end
        end
    end

    describe "try_again" do
        it "restarts the interrupted action when the reaction script is successfully finished" do
            fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_table_m.on_fault Roby::ChildFailedError do
                try_again
            end
            task_m = Roby::Task.new_submodel do
                terminates
            end
            action_m = Roby::Actions::Interface.new_submodel do
                describe("").returns(task_m)
                define_method :test do
                    parent, child = task_m.new, task_m.new
                    parent.depends_on child, role: "test"
                    plan.add(parent)
                    parent
                end
            end

            plan.use_fault_response_table fault_table_m
            plan.add_mission_task(parent = action_m.test.as_plan)
            parent = parent.as_service
            execute { parent.planning_task.start! }
            execute do
                parent.start!
                parent.test_child.start!
                parent.test_child.stop!
            end

            execute { parent.planning_task.start! }
            execute do
                parent.start!
                parent.test_child.start!
            end
        end
    end

    describe "the fault response" do
        attr_reader :error_m, :response_task_m, :table_m, :fault_handler_m
        attr_reader :root_task

        before do
            @error_m = Class.new(Roby::LocalizedError)
            @response_task_m = response_task_m = Roby::Task.new_submodel do
                terminates
            end
            @table_m = Roby::Coordination::FaultResponseTable.new_submodel
            @fault_handler_m = table_m.on_fault error_m do
                locate_on_origin
                response = task(response_task_m)
                execute response
            end

            plan.use_fault_response_table(table_m)
            plan.add_permanent_task(@root_task = Roby::Tasks::Simple.new)
        end

        it "registers a fault response task and starts it" do
            execute { root_task.start! }
            expect_execution { execution_engine.add_error(error_m.new(root_task)) }
                .to { have_handled_error_matching error_m.match.with_origin(root_task) }
            fault_handling_task = root_task.each_error_handler.to_a.first.first
            assert_kind_of Roby::Coordination::FaultHandlingTask, fault_handling_task
            assert_equal fault_handler_m, fault_handling_task.fault_handler
            assert fault_handling_task.running?
        end

        it "inhibits the localized error that caused it to trigger" do
            execute { root_task.start! }
            flexmock(execution_engine).should_receive(:warn).with("1 handled errors")
            flexmock(execution_engine).should_receive(:notify_exception).once
                                      .with(Roby::ExecutionEngine::EXCEPTION_HANDLED, error_m.to_execution_exception_matcher, any)

            execute { execution_engine.add_error(error_m.new(root_task)) }
            assert execution_engine.inhibited_exception?(error_m.new(root_task))
        end
    end
end
