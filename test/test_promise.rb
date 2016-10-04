require 'roby/test/self'

module Roby
    describe Promise do
        attr_reader :recorder
        before do
            @recorder = flexmock
        end
        it "registers the promise as pending work on the engine" do
            p = execution_engine.promise { }
            assert execution_engine.waiting_work.include?(p)
        end

        it "executes the promised work" do
            recorder.should_receive(:called).once
            execution_engine.promise { recorder.called }.execute
            execution_engine.join_all_waiting_work
        end

        describe "#on_success" do
            it "queues on_success handlers to be executed on the engine" do
                order = Array.new
                execution_engine.
                    promise { order << Thread.current }.
                    on_success { Thread.pass; order << Thread.current }.
                    then { order << Thread.current }.
                    execute

                execution_engine.join_all_waiting_work

                assert_equal 3, order.size
                refute_equal Thread.current, order[0]
                assert_equal Thread.current, order[1]
                refute_equal Thread.current, order[2]
            end
            
            it "raises if the promise is final" do
                p = execution_engine.promise { }
                flexmock(p).should_receive(:final?).and_return(true)
                assert_raises(Promise::Final) do
                    p.on_success { }
                end
            end

            it "raises if attempting to add more than one sucess handler to the same promise" do
                p = execution_engine.promise { }
                p.on_success { }
                assert_raises(Promise::AlreadyHasChild) do
                    p.on_success { }
                end
            end

            it "optionally executes on_success handlers on the thread pool" do
                order = Array.new
                execution_engine.
                    promise { order << Thread.current }.
                    on_success(in_engine: false) { Thread.pass; order << Thread.current }.
                    then { order << Thread.current }.
                    execute

                execution_engine.join_all_waiting_work

                assert_equal 3, order.size
                refute_equal Thread.current, order[0]
                refute_equal Thread.current, order[1]
                refute_equal Thread.current, order[2]
            end
        end

        describe "#on_error" do
            it "raises if attempting to add more than one error handler to the same promise" do
                p = execution_engine.promise { }
                p.on_error { }
                assert_raises(Promise::AlreadyHasChild) do
                    p.on_error { }
                end
            end
            
            it "raises if the promise is final" do
                p = execution_engine.promise { }
                flexmock(p).should_receive(:final?).and_return(true)
                assert_raises(Promise::Final) do
                    p.on_error { }
                end
            end

            it "marks the returned promise as final" do
                p = execution_engine.promise { }
                error_p = p.on_error { }
                assert error_p.final?
            end

            it "calls its block if the promise is rejected" do
                p = execution_engine.promise { raise ArgumentError }
                p.on_error   { recorder.error }
                recorder.should_receive(:error).once
                p.execute
                execution_engine.join_all_waiting_work
            end

            it "adds an error handler to a promise with a success handler" do
                p = execution_engine.promise { raise ArgumentError }
                p.on_success { recorder.success }
                p.on_error   { recorder.error }
                recorder.should_receive(:success).never
                recorder.should_receive(:error).once
                p.execute
                execution_engine.join_all_waiting_work
            end

            it "queues on_error handlers to be executed on the engine" do
                order = Array.new
                execution_engine.
                    promise { order << Thread.current; raise ArgumentError }.
                    on_error { order << Thread.current }.
                    execute

                execution_engine.join_all_waiting_work

                assert_equal 2, order.size
                refute_equal Thread.current, order[0]
                assert_equal Thread.current, order[1]
            end

            it "optionally executes on_error handlers on the thread pool" do
                order = Array.new
                execution_engine.
                    promise { order << Thread.current; raise "test" }.
                    on_error(in_engine: false) { Thread.pass; order << Thread.current }.
                    execute

                execution_engine.join_all_waiting_work

                assert_equal 2, order.size
                refute_equal Thread.current, order[0]
                refute_equal Thread.current, order[1]
            end
        end
        
        describe "#would_handle_rejections?" do
            it "returns false if there is no error handler at all" do
                p = execution_engine.promise { }
                refute p.would_handle_rejections?
            end

            it "returns true if the promise has an error handler" do
                p = execution_engine.promise { }
                p.on_error { }
                assert p.would_handle_rejections?
            end

            it "returns true if one of the promise children has an error handler" do
                p = execution_engine.promise { }
                p.on_success { }.on_success { }.on_error { }
                assert p.would_handle_rejections?
            end

            it "returns false if one of the promise parents has an error handler" do
                p = execution_engine.promise { }
                p.on_error { }
                refute p.on_success { }.would_handle_rejections?
            end
        end
        
        describe "#has_rejection_handled?" do
            it "returns false if there are no error handlers" do
                p = execution_engine.promise { raise "TEST" }
                p.on_success { }
                p.execute; p.wait;
                refute p.has_rejection_handled?
                # Add an error handler to avoid warnings on teardown
                p.on_error { }
            end
            it "returns true if itself or its children would handle it" do
                p = execution_engine.promise { raise "TEST" }
                p.on_error { }
                p.execute; p.wait;
                flexmock(p).should_receive(:would_handle_rejections?).and_return(true)
                assert p.has_rejection_handled?
            end
            it "returns true if the error was generated by one of its parent, and handled by it" do
                p = execution_engine.promise { raise "TEST" }
                p.on_error { }
                child = p.on_success { }
                grandchild = child.on_success { }
                p.execute; grandchild.wait;
                assert grandchild.has_rejection_handled?
            end
            it "returns true if the error was generated by one of its parent, and there was an error handler on the way" do
                p = execution_engine.promise { raise "TEST" }
                child = p.on_success { }
                child.on_error { }
                grandchild = child.on_success { }
                p.execute; grandchild.wait;
                assert grandchild.has_rejection_handled?
            end
        end
    end
end
