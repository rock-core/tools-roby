require 'roby/test/self'
module Roby
    describe PlanService do
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

        describe "transaction behaviour" do
            it "does not call replacement handlers for replacements happening in the transaction" do
                recorder = flexmock
                recorder.should_receive(:called).never
                service.on_replacement do
                    recorder.called
                end

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    p2 = trsc[t2]
                    trsc.replace_task(p1, p2)
                end
            end
            it "calls replacement handlers for replacements happening at commit time" do
                recorder = flexmock
                recorder.should_receive(:called).with(t1, t2).once
                service.on_replacement do |old_task, new_task|
                    recorder.called(old_task, new_task)
                end

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    p2 = trsc[t2]
                    trsc.replace_task(p1, p2)
                    trsc.commit_transaction
                end
            end
            it "calls new replacement handlers for replacements happening at commit time" do
                recorder = flexmock
                recorder.should_receive(:called).with(t1, t2).once

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    p2 = trsc[t2]
                    service = PlanService.get(p1)
                    service.on_replacement do |old_task, new_task|
                        recorder.called(old_task, new_task)
                    end

                    trsc.replace_task(p1, p2)
                    trsc.commit_transaction
                end
            end
            it "registers replacement handlers on the underlying object at commit time" do
                recorder = flexmock
                recorder.should_receive(:called).with(t1, t2).once

                plan.in_transaction do |trsc|
                    p1 = trsc[t1]
                    service = PlanService.get(p1)
                    service.on_replacement do |old_task, new_task|
                        recorder.called(old_task, new_task)
                    end

                    trsc.commit_transaction
                end

                plan.replace_task(t1, t2)
            end
        end
    end
end

