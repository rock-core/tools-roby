require 'roby/test/self'
require 'roby/interface'
require 'roby/tasks/simple'

describe Roby::Interface::Interface do
    attr_reader :plan
    attr_reader :app
    attr_reader :interface
    attr_reader :job_task_m

    before do
        @app = Roby::Application.new
        @plan = app.plan
        register_plan(plan)
        @interface = Roby::Interface::Interface.new(app)
        @job_task_m = Roby::Task.new_submodel
        job_task_m.provides Roby::Interface::Job
    end

    describe "#actions" do
        it "should list existing actions" do
            actions = Roby::Actions::Interface.new_submodel do
                describe "blablabla"
                def an_action
                end
            end
            app.planners << actions
            assert_equal [actions.an_action.model], interface.actions
        end
    end

    describe "job_id_of_task" do
        it "should return the job ID of a job task" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            assert_equal 10, interface.job_id_of_task(job_task)
        end
        it "should return the job ID of the placeholder task for a job task" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add(planned_task = Roby::Task.new)
            planned_task.planned_by job_task
            assert_equal 10, interface.job_id_of_task(planned_task)
        end
        it "should return nil if the job ID is not set" do
            plan.add(job_task = job_task_m.new(job_id: nil))
            plan.add(planned_task = Roby::Task.new)
            planned_task.planned_by job_task
            assert_nil interface.job_id_of_task(job_task)
            assert_nil interface.job_id_of_task(planned_task)
        end
        it "should return nil for plain tasks" do
            plan.add(plain = Roby::Task.new)
            assert_nil interface.job_id_of_task(plain)
        end
    end

    describe "#jobs" do
        it "should return the set of job tasks existing in the plan" do
            plan.add_mission_task(job_task = job_task_m.new(job_id: 10))
            assert_equal Hash[10 => [:ready, job_task, job_task]], interface.jobs
        end
        it "should return the planned task if the job task has one" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission_task(planned_task = Roby::Task.new)
            planned_task.planned_by job_task
            assert_equal Hash[10 => [:planning_ready, planned_task, job_task]], interface.jobs
        end
        it "should not return job tasks that have no job ID" do
            plan.add(job_task_m.new)
            assert_equal Hash[], interface.jobs
        end
    end

    describe "find_job_by_id" do
        it "should return the corresponding job task if there is one" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            assert_equal job_task, interface.find_job_by_id(10)
        end
        it "should return nil if no job with the given ID exists" do
            assert_nil interface.find_job_by_id(10)
        end
    end

    describe "job state tracking" do
        attr_reader :job_task, :task, :recorder, :job_listener
        before do
            plan.add(@job_task = job_task_m.new(job_id: 10))
            plan.add_mission_task(@task = Roby::Tasks::Simple.new)
            task.planned_by job_task
            flexmock(job_task).should_receive(:job_name).and_return("the job")
            @recorder = Array.new
            @job_listener = interface.on_job_notification do |event, id, name, *args|
                recorder << [event, id, name, *args]
            end
        end

        after do
            interface.remove_job_listener(job_listener)
        end

        def assert_received_notifications(*expected)
            expected.each_with_index do |expected, i|
                if !recorder[i]
                    flunk "expected notification #{i} to be #{expected.inspect}\nbut there was none"
                elsif !expected.each_with_index.all? { |v, v_i| v === recorder[i][v_i] }
                    flunk "expected notification #{i} to be #{expected.inspect}\nbut got #{recorder[i].inspect}"
                end
            end
        end

        it "starts notifications when starting a job" do
            task, job_task = nil
            flexmock(interface.app).should_receive(:action_from_name).and_return do
                task = Roby::Tasks::Simple.new
                job_task = job_task_m.new(job_id: 11)
                task.planned_by(job_task)
                [nil, flexmock(plan_pattern: task)]
            end
            interface.start_job(:whatever)
            interface.push_pending_job_notifications
            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 11, any, any, any],
                [Roby::Interface::JOB_PLANNING_READY, 11, any]
        end

        it "should notify of job state changes" do
            interface.monitor_job(job_task, task)
            expect_execution do
                job_task.start!
                job_task.success_event.emit
            end.to_run
            expect_execution do
                task.start!
                task.success_event.emit
            end.to_run
            expect_execution { plan.remove_task(task) }.to_run
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_PLANNING, 10, "the job"],
                [Roby::Interface::JOB_READY, 10, "the job"],
                [Roby::Interface::JOB_STARTED, 10, "the job"],
                [Roby::Interface::JOB_SUCCESS, 10, "the job"],
                [Roby::Interface::JOB_FINALIZED, 10, "the job"]
        end

        it "notifies of planning failures" do
            interface.monitor_job(job_task, task)
            expect_execution { job_task.start! }.to_run
            expect_execution { job_task.failed_event.emit }.
                garbage_collect(true).to { have_error_matching Roby::PlanningFailedError }
            interface.push_pending_job_notifications
            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_PLANNING, 10, "the job"],
                [Roby::Interface::JOB_PLANNING_FAILED, 10, "the job"],
                [Roby::Interface::JOB_FINALIZED, 10, "the job"]
        end

        it "should notify of placeholder task change" do
            plan.add(new_task = Roby::Tasks::Simple.new(id: task.id))
            new_task.planned_by job_task

            interface.monitor_job(job_task, task)
            plan.replace_task(task, new_task)
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_REPLACED, 10, "the job", new_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"]
        end


        it "notifies the current state of the new placeholder task" do
            plan.add(new_task = Roby::Tasks::Simple.new(id: task.id))
            new_task.planned_by job_task
            expect_execution { new_task.start! }.to_run

            interface.monitor_job(job_task, task)
            plan.replace_task(task, new_task)
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_REPLACED, 10, "the job", new_task],
                [Roby::Interface::JOB_STARTED, 10, "the job"]
        end

        it "notifies the current state of the new placeholder task" do
            plan.add(new_task = Roby::Tasks::Simple.new(id: task.id))
            new_task.planned_by job_task
            expect_execution { new_task.start! }.to_run

            interface.monitor_job(job_task, task)
            plan.replace_task(task, new_task)
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_REPLACED, 10, "the job", new_task],
                [Roby::Interface::JOB_STARTED, 10, "the job"]
        end

        it "does not send a drop notification when a replacement is done in a transaction" do
            interface.monitor_job(job_task, task)
            plan.in_transaction do |t|
                t.add(new_task = Roby::Tasks::Simple.new(id: task.id))
                new_task.planned_by t[job_task]
                t.replace(t[task], new_task)
                t.commit_transaction
            end
            interface.push_pending_job_notifications
            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_REPLACED, 10, "the job", any]
        end

        it "notifies if a job is dropped" do
            interface.monitor_job(job_task, task)
            plan.unmark_mission_task(task)
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_DROPPED, 10, "the job"]
        end

        it "does not send further notifications if a job has been dropped" do
            interface.monitor_job(job_task, task)
            plan.unmark_mission_task(task)
            interface.push_pending_job_notifications
            expect_execution do
                job_task.start!
                job_task.success_event.emit
            end.to_run
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_DROPPED, 10, "the job"]
        end

        it "recaptures a job" do
            interface.monitor_job(job_task, task)
            plan.unmark_mission_task(task)
            interface.push_pending_job_notifications
            expect_execution do
                job_task.start!
                job_task.success_event.emit
            end.to_run
            interface.push_pending_job_notifications
            plan.add_mission_task(task)
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_DROPPED, 10, "the job"],
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_READY, 10, "the job"]
        end

        it "disable notifications if the replacement task has not the same job ID" do
            plan.add(new_task = Roby::Tasks::Simple.new(id: task.id))
            interface.monitor_job(job_task, task)
            plan.replace(task, new_task)
            interface.push_pending_job_notifications
            expect_execution do
                task.start!
                new_task.start!
            end.to_run
            interface.push_pending_job_notifications

            assert_received_notifications \
                [Roby::Interface::JOB_MONITORED, 10, "the job", task, job_task],
                [Roby::Interface::JOB_PLANNING_READY, 10, "the job"],
                [Roby::Interface::JOB_LOST, 10, "the job", new_task]
        end

        it "allows to remove a listener completely" do
            interface.monitor_job(job_task, task)
            interface.remove_job_listener(job_listener)
            expect_execution { task.start! }.to_run
            assert recorder.empty?
        end
    end

    describe "exception notifications" do
        attr_reader :parent_task, :child_task, :recorder, :exception_listener
        before do
            plan.add(@parent_task = Roby::Tasks::Simple.new)
            plan.add(@child_task = Roby::Tasks::Simple.new)
            @recorder = flexmock
            @exception_listener = interface.on_exception do |*args|
                recorder.called(*args)
            end
            execution_engine.display_exceptions = false
        end

        after do
            execution_engine.display_exceptions = true
        end

        it "calls the notification handlers when the engine notifies about an exception" do
            localized_error_m = Class.new(Roby::LocalizedError)
            exception = localized_error_m.new(child_task).to_execution_exception
            recorder.should_receive(:called).once.
                with(Roby::ExecutionEngine::EXCEPTION_FATAL, exception, Set[child_task, parent_task], Set.new)
            execution_engine.notify_exception(Roby::ExecutionEngine::EXCEPTION_FATAL, exception, Set[parent_task, child_task])
        end

        it "allows to remove a listener" do
            localized_error_m = Class.new(Roby::LocalizedError)
            exception = localized_error_m.new(child_task).to_execution_exception
            interface.remove_exception_listener(exception_listener)
            recorder.should_receive(:called).never
            execution_engine.notify_exception(Roby::ExecutionEngine::EXCEPTION_FATAL, exception, Set[parent_task, child_task])
        end
    end

    describe "#kill_job" do
        attr_reader :task
        before do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission_task(@task = Roby::Tasks::Simple.new)
            task.planned_by job_task
        end
        it "returns true for an existing job" do
            assert interface.kill_job(10)
        end
        it "returns false for a non-existent job" do
            assert !interface.kill_job(20)
        end
        it "unmarks the job as mission" do
            interface.kill_job 10
            assert !plan.mission_task?(task)
        end
        it "forcefully stops a running job" do
            expect_execution { task.start! }.to_run
            interface.kill_job 10
            assert task.finished?
        end
    end

    describe "#drop_job" do
        attr_reader :task
        before do
            plan.add(@job_task = job_task_m.new(job_id: 10))
            plan.add_mission_task(@task = Roby::Tasks::Simple.new)
            task.planned_by @job_task
        end
        it "returns true for an existing job" do
            assert interface.drop_job(10)
        end
        it "returns false for a non-existent job" do
            refute interface.drop_job(20)
        end
        it "removes the planning task relation" do
            interface.drop_job(10)
            assert_equal [], task.each_planning_task.to_a
        end
        it "unmarks the job as mission" do
            interface.drop_job 10
            refute plan.mission_task?(task)
        end
        it "does not stops a running job" do
            expect_execution { task.start! }.to_run
            interface.drop_job 10
            assert task.running?
        end
        
        describe "multiple planning tasks" do
            before do
                @other_job_task = job_task_m.new(job_id: 20)
                task.add_planning_task @other_job_task
            end

            it "does not unmark as mission" do
                interface.drop_job 10
                assert plan.mission_task?(task)
            end

            it "does remove the planning relation" do
                interface.drop_job 10
                assert_equal [@other_job_task], task.each_planning_task.to_a
            end
        end
    end

    describe "#find_job_info_by_id" do
        it "returns nil on a non-existent job" do
            assert !interface.find_job_info_by_id(20)
        end
        it "returns the job information of a job" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission_task(task = Roby::Tasks::Simple.new)
            task.planned_by job_task
            flexmock(interface).should_receive(:job_state).with(task).
                and_return(expected_state = flexmock)
            job_state, placeholder_task, planning_task = interface.find_job_info_by_id(10)
            assert_equal expected_state, job_state
            assert_equal task, placeholder_task
            assert_equal job_task, planning_task
        end
        it "returns the same task as placeholder and planning task for standalone job tasks" do
            plan.add_mission_task(job_task = job_task_m.new(job_id: 10))
            _, task, planning_task = interface.find_job_info_by_id(10)
            assert_equal job_task, task
            assert_equal job_task, planning_task
        end
        it "returns the job information of a job" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission_task(task = Roby::Tasks::Simple.new)
            task.planned_by job_task
            job_state, task, planning_task = interface.find_job_info_by_id(20)
        end
    end

    describe "notification handlers" do
        it "#on_notifications registers a notification handler" do
            recorder = flexmock
            interface.on_notification do |source, level, message|
                recorder.called(source, level, message)
            end
            recorder.should_receive(:called).
                with(source = flexmock, level = flexmock, message = flexmock).
                once
            app.notify(source, level, message)
        end
        it "#remove_notification_listener removes a registered notification handler" do
            recorder = flexmock
            handler_id = interface.on_notification do |source, level, message|
                recorder.called
            end
            interface.remove_notification_listener(handler_id)
            recorder.should_receive(:called).never
            app.notify(flexmock, flexmock, flexmock)
        end
    end

    describe "UI event handlers" do
        it "registers a new handler for UI events" do
            recorder = flexmock
            recorder.should_receive(:called).with(:test_event, [0, 2, 3]).once
            interface.on_ui_event do |event, *args|
                recorder.called(event, args)
            end
            app.ui_event(:test_event, 0, 2, 3)
        end
        it "#remove_notification_listener removes a registered notification handler" do
            recorder = flexmock
            recorder.should_receive(:called).never
            id = interface.on_ui_event do |event, *args|
                recorder.called
            end
            interface.remove_ui_event_listener(id)
            app.ui_event(:test_event, 0, 2, 3)
        end
    end

    describe "cycle end handlers" do
        it "registers a new handler called when the execution engine announces a cycle end" do
            recorder = flexmock
            interface.on_cycle_end { recorder.called }
            recorder.should_receive(:called).once
            app.plan.execution_engine.cycle_end(Hash.new)
        end
        it "calls #push_pending_job_notifications before the handler" do
            recorder = flexmock
            interface.on_cycle_end { recorder.called }

            flexmock(interface).should_receive(:push_pending_job_notifications).once.globally.ordered
            recorder.should_receive(:called).once.globally.ordered
            app.plan.execution_engine.cycle_end(Hash.new)
        end
        it "allows to remove an added handler" do
            recorder = flexmock
            listener_id = interface.on_cycle_end { recorder.called }
            recorder.should_receive(:called).never
            interface.remove_cycle_end(listener_id)
            app.plan.execution_engine.cycle_end(Hash.new)
        end
    end

    describe "#enable_backtrace_filtering" do
        it "disables backtrace filtering on the app" do
            interface.enable_backtrace_filtering(enable: false)
            refute interface.app.filter_backtraces?
        end
        it "reenables backtrace filtering on the app" do
            interface.enable_backtrace_filtering(enable: false)
            interface.enable_backtrace_filtering(enable: true)
            assert interface.app.filter_backtraces?
        end
    end

    describe "#log_dir" do
        it "returns the app's log dir" do
            flexmock(interface.app).should_receive(:log_dir).and_return(result = flexmock)
            assert_equal result, interface.log_dir
        end
    end
end

