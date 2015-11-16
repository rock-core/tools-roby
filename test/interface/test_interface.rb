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
        Roby::ExecutionEngine.new(app.plan)
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
            assert_equal nil, interface.job_id_of_task(job_task)
            assert_equal nil, interface.job_id_of_task(planned_task)
        end
        it "should return nil for plain tasks" do
            plan.add(plain = Roby::Task.new)
            assert_equal nil, interface.job_id_of_task(plain)
        end
    end

    describe "#jobs" do
        it "should return the set of job tasks existing in the plan" do
            plan.add_mission(job_task = job_task_m.new(job_id: 10))
            assert_equal Hash[10 => [:ready, job_task, job_task]], interface.jobs
        end
        it "should return the planned task if the job task has one" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission(planned_task = Roby::Task.new)
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
            assert_equal nil, interface.find_job_by_id(10)
        end
    end

    describe "job state tracking" do
        attr_reader :job_task, :task, :recorder, :job_listener
        before do
            plan.add(@job_task = job_task_m.new(job_id: 10))
            plan.add_mission(@task = Roby::Tasks::Simple.new)
            task.planned_by job_task
            flexmock(job_task).should_receive(:job_name).and_return("the job")
            @recorder = flexmock
            @job_listener = interface.on_job_notification do |event, id, name, *args|
                recorder.called(event, id, name, *args)
            end
        end

        after do
            interface.remove_job_listener(job_listener)
        end

        it "starts notifications when starting a job" do
            task, job_task = nil
            flexmock(interface.app).should_receive(:action_from_name).and_return do
                task = Roby::Tasks::Simple.new
                job_task = job_task_m.new(job_id: 11)
                task.planned_by(job_task)
                [nil, flexmock(plan_pattern: task)]
            end
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 11, any, any, any).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 11, any).once.ordered
            interface.start_job(:whatever)
            interface.push_pending_job_notifications
        end

        it "should notify of job state changes" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_STARTED, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_SUCCESS, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_FINALIZED, 10, "the job").once.ordered

            interface.monitor_job(task.planning_task, task)
            job_task.start!
            job_task.success_event.emit
            task.start!
            task.success_event.emit
            plan.remove_object(task)
            interface.push_pending_job_notifications
        end

        it "notifies of planning failures" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_FAILED, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_FINALIZED, 10, "the job").once.ordered
            interface.monitor_job(task.planning_task, task)
            job_task.start!
            inhibit_fatal_messages do
                assert_raises(Roby::PlanningFailedError) { job_task.failed_event.emit }
            end
            interface.push_pending_job_notifications
        end

        it "should notify of placeholder task change" do
            plan.add(new_task = Roby::Tasks::Simple.new(id: task.id))
            new_task.planned_by job_task
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_REPLACED, 10, "the job", new_task).once.ordered

            interface.monitor_job(task.planning_task, task)
            plan.replace_task(task, new_task)
            interface.push_pending_job_notifications
        end


        it "does not send a drop notification when a replacement is done in a transaction" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_REPLACED, 10, "the job", any).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", any, any).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job", any).once.ordered

            interface.monitor_job(task.planning_task, task)
            plan.in_transaction do |t|
                t.add(new_task = Roby::Tasks::Simple.new(id: task.id))
                new_task.planned_by t[job_task]
                t.replace(t[task], new_task)
                t.commit_transaction
            end
            interface.push_pending_job_notifications
        end

        it "notifies if a job is dropped" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_DROPPED, 10, "the job").once.ordered

            interface.monitor_job(task.planning_task, task)
            plan.unmark_mission(task)
            interface.push_pending_job_notifications
        end

        it "does not send further notifications if a job has been dropped" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_DROPPED, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING, 10, "the job").never

            interface.monitor_job(task.planning_task, task)
            plan.unmark_mission(task)
            interface.push_pending_job_notifications
            job_task.start!
            job_task.success_event.emit
            interface.push_pending_job_notifications
        end

        it "recaptures a job" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_DROPPED, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING, 10, "the job").never
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_READY, 10, "the job").once.ordered

            interface.monitor_job(task.planning_task, task)
            plan.unmark_mission(task)
            interface.push_pending_job_notifications
            job_task.start!
            job_task.success_event.emit
            interface.push_pending_job_notifications
            plan.add_mission(task)
            interface.push_pending_job_notifications
        end

        it "disable notifications if the replacement task has not the same job ID" do
            plan.add(new_task = Roby::Tasks::Simple.new(id: task.id))
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task, task.planning_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_LOST, 10, "the job", new_task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_STARTED, 10, "the job").never

            interface.monitor_job(task.planning_task, task)
            plan.replace(task, new_task)
            interface.push_pending_job_notifications
            task.start!
            new_task.start!
            interface.push_pending_job_notifications
        end

        it "allows to remove a listener completely" do
            recorder.should_receive(:called).never
            interface.monitor_job(task.planning_task, task)
            interface.remove_job_listener(job_listener)
            task.start!
        end
    end

    describe "exception notifications" do
        attr_reader :parent_task, :child_task, :recorder, :exception_listener
        before do
            plan.add(@parent_task = Roby::Tasks::Simple.new)
            plan.add(@child_task = Roby::Tasks::Simple.new)
            parent_task.depends_on child_task
            parent_task.start!
            child_task.start!
            @recorder = flexmock
            @exception_listener = interface.on_exception do |*args|
                recorder.called(*args)
            end
        end

        it "should call the handlers with the generated exception" do
            exception_validator = lambda do |error|
                error.origin == child_task && error.exception.class == Roby::ChildFailedError
            end
            recorder.should_receive(:called).with(Roby::ExecutionEngine::EXCEPTION_FATAL, exception_validator, [child_task, parent_task])
            inhibit_fatal_messages do
                assert_raises(Roby::ChildFailedError) do
                    child_task.stop!
                end
            end
        end

        it "allows to remove a listener" do
            recorder.should_receive(:called).never
            interface.remove_exception_listener(exception_listener)
            inhibit_fatal_messages do
                assert_raises(Roby::ChildFailedError) do
                    child_task.stop!
                end
            end
        end
    end

    describe "#kill_job" do
        attr_reader :task
        before do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission(@task = Roby::Tasks::Simple.new)
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
            assert !plan.mission?(task)
        end
        it "forcefully stops a running job" do
            task.start!
            interface.kill_job 10
            assert task.finished?
        end
    end

    describe "#drop_job" do
        attr_reader :task
        before do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission(@task = Roby::Tasks::Simple.new)
            task.planned_by job_task
        end
        it "returns true for an existing job" do
            assert interface.drop_job(10)
        end
        it "returns false for a non-existent job" do
            assert !interface.drop_job(20)
        end
        it "unmarks the job as mission" do
            interface.drop_job 10
            assert !plan.mission?(task)
        end
        it "does not stops a running job" do
            task.start!
            interface.drop_job 10
            assert task.running?
        end
    end

    describe "#find_job_info_by_id" do
        it "returns nil on a non-existent job" do
            assert !interface.find_job_info_by_id(20)
        end
        it "returns the job information of a job" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission(task = Roby::Tasks::Simple.new)
            task.planned_by job_task
            flexmock(interface).should_receive(:job_state).with(task).
                and_return(expected_state = flexmock)
            job_state, placeholder_task, planning_task = interface.find_job_info_by_id(10)
            assert_equal expected_state, job_state
            assert_equal task, placeholder_task
            assert_equal job_task, planning_task
        end
        it "returns the same task as placeholder and planning task for standalone job tasks" do
            plan.add_mission(job_task = job_task_m.new(job_id: 10))
            _, task, planning_task = interface.find_job_info_by_id(10)
            assert_equal job_task, task
            assert_equal job_task, planning_task
        end
        it "returns the job information of a job" do
            plan.add(job_task = job_task_m.new(job_id: 10))
            plan.add_mission(task = Roby::Tasks::Simple.new)
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
end

