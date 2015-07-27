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
            plan.add(job_task = job_task_m.new(:job_id => 10))
            assert_equal 10, interface.job_id_of_task(job_task)
        end
        it "should return the job ID of the placeholder task for a job task" do
            plan.add(job_task = job_task_m.new(:job_id => 10))
            plan.add(planned_task = Roby::Task.new)
            planned_task.planned_by job_task
            assert_equal 10, interface.job_id_of_task(planned_task)
        end
        it "should return nil if the job ID is not set" do
            plan.add(job_task = job_task_m.new(:job_id => nil))
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
            plan.add(job_task = job_task_m.new(:job_id => 10))
            assert_equal Hash[10 => [:ready, job_task, job_task]], interface.jobs
        end
        it "should return the planned task if the job task has one" do
            plan.add(job_task = job_task_m.new(:job_id => 10))
            plan.add(planned_task = Roby::Task.new)
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
            plan.add(job_task = job_task_m.new(:job_id => 10))
            assert_equal job_task, interface.find_job_by_id(10)
        end
        it "should return nil if no job with the given ID exists" do
            assert_equal nil, interface.find_job_by_id(10)
        end
    end

    describe "job state tracking" do
        attr_reader :job_task, :task, :recorder, :job_listener
        before do
            plan.add(@job_task = job_task_m.new(:job_id => 10))
            plan.add(@task = Roby::Tasks::Simple.new)
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

        it "should notify of job state changes" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task).once.ordered
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
        end

        it "should notify of placeholder task change" do
            plan.add(new_task = Roby::Tasks::Simple.new(:id => task.id))
            new_task.planned_by job_task
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_REPLACED, 10, "the job", new_task).once.ordered

            interface.monitor_job(task.planning_task, task)
            plan.replace_task(task, new_task)
        end

        it "disable notifications if the replacement task has not the same job ID" do
            plan.add(new_task = Roby::Tasks::Simple.new(:id => task.id))
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_STARTED, 10, "the job").never

            interface.monitor_job(task.planning_task, task)
            plan.replace(task, new_task)
            task.start!
            new_task.start!
        end

        it "allows to remove a listener completely" do
            recorder.should_receive(:called).with(Roby::Interface::JOB_MONITORED, 10, "the job", task).once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_PLANNING_READY, 10, "the job").once.ordered
            recorder.should_receive(:called).with(Roby::Interface::JOB_STARTED, 10, "the job").never
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
end

