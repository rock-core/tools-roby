require 'roby/test/self'
module Roby
    describe PlanService do
        let(:spy) { flexmock }

        attr_reader :t1, :t2, :service
        before do
            root, @t1, @t2 = prepare_plan add: 3, model: Tasks::Simple
            root.depends_on @t1, model: Tasks::Simple
            root.depends_on @t2, model: Tasks::Simple
            @service = PlanService.get(t1)
        end

        it "is deregistered from the plan on finalization" do
            plan.remove_object(t1)
            assert !plan.find_plan_service(t1)
        end

        describe '.get' do
            it "returns the same service object for the same task" do
                assert_same service, PlanService.get(t1)
            end
            it "returns the same service object for the service's current task" do
                plan.replace t1, t2
                refute_same service, PlanService.get(t1)
                assert_same service, PlanService.get(t2)
            end
        end

        it "tracks the task's replacements" do
            assert_equal(t1, service.task)
            plan.replace(t1, t2)
            assert_equal(t2, service.task)
        end

        it "calls event handlers only for the current underlying task" do
            mock = flexmock
            mock.should_receive(:called_on).with(t2).once
            service.on :success do |event|
                mock.called_on(event.task)
            end

            t1.start!
            t2.start!
            plan.replace(t1, t2)
            t1.success!
            t2.success!
        end

        it "calls finalization handlers only for the current underlying task" do
            mock = flexmock
            mock.should_receive(:called).with(t2).once
            service.when_finalized do
                mock.called(service.task)
            end

            plan.replace(t1, t2)
            plan.remove_object(t1)
            plan.remove_object(t2)
        end

        describe "#on_plan_status_change" do
            attr_reader :task, :service
            before do
                plan.add(@task = Roby::Task.new)
                @service = Roby::PlanService.new(task)
            end
            it "is called with the task's initial normal state" do
                spy.should_receive(:called).with(:normal).once
                service.on_plan_status_change { |state| spy.called(state) }
            end
            it "is called with the task's initial mission state" do
                plan.add_mission(task)
                spy.should_receive(:called).with(:mission).once
                service.on_plan_status_change { |state| spy.called(state) }
            end
            it "is called with the task's initial permanent state" do
                plan.add_permanent(task)
                spy.should_receive(:called).with(:permanent).once
                service.on_plan_status_change { |state| spy.called(state) }
            end
            it "is called when the task is marked as a mission" do
                spy.should_receive(:called).with(:normal).once.ordered
                spy.should_receive(:called).with(:mission).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.add_mission(task)
            end
            it "is called when the task is unmarked as mission" do
                plan.add_mission(task)
                spy.should_receive(:called).with(:mission).once.ordered
                spy.should_receive(:called).with(:normal).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.unmark_mission(task)
            end
            it "is not called when Plan#add_mission is called on a task that is already a mission" do
                spy.should_receive(:called).with(:normal).once.ordered
                spy.should_receive(:called).with(:mission).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.add_mission(task)
                plan.add_mission(task)
            end
            it "is not called when Plan#unmark_mission is called on a task that is not a mission" do
                spy.should_receive(:called).with(:normal).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.unmark_mission(task)
            end
            it "is called when the task is marked as permanent" do
                spy.should_receive(:called).with(:normal).once.ordered
                spy.should_receive(:called).with(:permanent).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.add_permanent(task)
            end
            it "is called when the task is unmarked as permanent" do
                plan.add_permanent(task)
                spy.should_receive(:called).with(:permanent).once.ordered
                spy.should_receive(:called).with(:normal).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.unmark_permanent(task)
            end
            it "is not called when Plan#add_permanent is called on a task that is already permanent" do
                spy.should_receive(:called).with(:normal).once.ordered
                spy.should_receive(:called).with(:permanent).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.add_permanent(task)
                plan.add_permanent(task)
            end
            it "is not called when Plan#unmark_permanent is called on a task that is not permanent" do
                spy.should_receive(:called).with(:normal).once.ordered
                service.on_plan_status_change { |state| spy.called(state) }
                plan.unmark_permanent(task)
            end
        end

        describe "transaction behaviour" do
            it "does not call plan status change handlers within the transaction" do
                spy.should_receive(:called).once
                service.on_plan_status_change { spy.called }

                plan.in_transaction do |t|
                    proxy = t[service.task]
                    t.add_mission(proxy)
                end
            end

            it "calls plan status change on commit " do
                spy.should_receive(:called).with(:normal).once.ordered
                spy.should_receive(:called).with(:mission).once.ordered
                service.on_plan_status_change { |s| spy.called(s) }

                plan.in_transaction do |t|
                    proxy = t[service.task]
                    t.add_mission(proxy)
                    t.commit_transaction
                end
            end

            it "registers new status change handlers on commit" do
                spy.should_receive(:called).twice
                plan.in_transaction do |t|
                    t[service].on_plan_status_change { spy.called }
                    t.commit_transaction
                end
                plan.add_mission(service.task)
            end
            it "does not register new status change handlers on discard" do
                spy.should_receive(:called).never
                plan.in_transaction do |t|
                    t[service].on_plan_status_change { spy.called }
                end
                plan.add_mission(service.task)
            end

            it "allows to access the service using the #[] syntax" do
                plan.in_transaction do |t|
                    t_proxy = t[service.task]
                    assert_same PlanService.get(t_proxy), t[service]
                end
            end

            it "calls plan status changes on new handlers on commit" do
                spy.should_receive(:called).with(:normal).once.ordered
                spy.should_receive(:called).with(:mission).once.ordered

                plan.in_transaction do |t|
                    t.add_mission(t_proxy = t[service.task])
                    s_proxy = PlanService.get(t_proxy)
                    s_proxy.on_plan_status_change { |s| spy.called(s) }
                    t.commit_transaction
                end
            end

            it "does not call replacement handlers for replacements happening in the transaction" do
                spy.should_receive(:called).never
                service.on_replacement do
                    spy.called
                end

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    p2 = trsc[t2]
                    trsc.replace_task(p1, p2)
                end
            end
            it "calls replacement handlers for replacements happening at commit time" do
                spy.should_receive(:called).with(t1, t2).once
                service.on_replacement do |old_task, new_task|
                    spy.called(old_task, new_task)
                end

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    p2 = trsc[t2]
                    trsc.replace_task(p1, p2)
                    trsc.commit_transaction
                end
            end
            it "calls new replacement handlers for replacements happening at commit time" do
                spy.should_receive(:called).with(t1, t2).once

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    p2 = trsc[t2]
                    service = PlanService.get(p1)
                    service.on_replacement do |old_task, new_task|
                        spy.called(old_task, new_task)
                    end

                    trsc.replace_task(p1, p2)
                    trsc.commit_transaction
                end
            end
            it "registers replacement handlers on the underlying object at commit time" do
                spy.should_receive(:called).with(t1, t2).once
                plan.in_transaction do |trsc|
                    trsc[service].on_replacement do |old_task, new_task|
                        spy.called(old_task, new_task)
                    end
                    trsc.commit_transaction
                end
                plan.replace_task(t1, t2)
            end
            it "does not register new replacement handlers on discard" do
                spy.should_receive(:called).never
                plan.in_transaction do |trsc|
                    trsc[service].on_replacement do |old_task, new_task|
                        spy.called(old_task, new_task)
                    end
                end
                plan.replace_task(t1, t2)
            end
        end
    end
end

