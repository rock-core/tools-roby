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

        it "provides a stringified description" do
            p = execution_engine.promise(description: 'the promise description') { }
            assert_match /the promise description/, p.to_s
        end

        describe "#pretty_print" do
            it "shows all the steps" do
                p = execution_engine.promise(description: 'the promise description')
                p.on_success(description: "first step")
                p.then(description: "second step")
                p.on_error(description: "if something fails")
                text = PP.pp(p, "")
                assert_equal <<-EOD, text
Roby::Promise(the promise description).
  on_success(first step).
  then(second step).
  on_error(if something fails, in_engine: true)
                EOD
            end

            it "properly handles a promise without steps" do
                p = execution_engine.promise(description: 'the promise description')
                text = PP.pp(p, "")
                assert_equal <<-EOD, text
Roby::Promise(the promise description)
                EOD
            end

            it "properly handles a promise without on_error" do
                p = execution_engine.promise(description: 'the promise description')
                p.on_success(description: 'first step')
                p.then(description: 'second step')
                text = PP.pp(p, "")
                assert_equal <<-EOD, text
Roby::Promise(the promise description).
  on_success(first step).
  then(second step)
                EOD
            end

            it "properly handles a promise with only an error handler" do
                p = execution_engine.promise(description: 'the promise description')
                p.on_error(description: "error handler") { }
                text = PP.pp(p, "")
                assert_equal <<-EOD, text
Roby::Promise(the promise description).
  on_error(error handler, in_engine: true)
                EOD
            end
        end

        describe "state predicates" do
            it "is unscheduled at creation" do
                p = execution_engine.promise { }
                assert p.unscheduled?
                refute p.pending?
                refute p.complete?
            end
            it "is pending when waiting for an executor" do
                executor = Concurrent::SingleThreadExecutor.new
                barrier  = Concurrent::CyclicBarrier.new(2)
                Concurrent::Promise.new(executor: executor) do
                    2.times { barrier.wait }
                end.execute
                barrier.wait
                p = execution_engine.promise(executor: executor) { }.execute
                refute p.unscheduled?
                assert p.pending?
                refute p.complete?
                barrier.wait; p.wait
            end
            it "is complete and fulfilled once the whole pipeline finished successfuly" do
                p = execution_engine.promise { }.execute
                p.wait
                refute p.unscheduled?
                refute p.pending?
                assert p.complete?
                assert p.fulfilled?
            end
            it "is complete and fulfilled once the whole pipeline finished successfuly even if an error handler has been defined" do
                p = execution_engine.promise { }.execute
                p.on_error { }
                p.wait
                refute p.unscheduled?
                refute p.pending?
                assert p.complete?
                assert p.fulfilled?
            end
            it "is not complete if the error handler is being executed" do
                p = execution_engine.promise { raise }
                barrier = Concurrent::CyclicBarrier.new(2)
                p.on_error(in_engine: false) do
                    barrier.wait; barrier.wait
                end
                p.execute
                barrier.wait
                refute p.unscheduled?
                assert p.pending?
                refute p.complete?
            end
            it "is complete and rejected if the error handler has finished execution" do
                p = execution_engine.promise { raise }
                barrier = Concurrent::CyclicBarrier.new(2)
                p.on_error(in_engine: false) { }
                p.execute
                execution_engine.join_all_waiting_work
                refute p.unscheduled?
                refute p.pending?
                assert p.complete?
                assert p.rejected?
            end
        end

        describe "#before" do
            attr_reader :promise
            before do
                @promise = execution_engine.promise
            end
            def execute_promise(promise)
                promise.execute
                execution_engine.join_all_waiting_work
            end

            it "adds a step in front of all existing steps" do
                order = Array.new
                promise.on_success { order << 1 }
                promise.before { order << 0 }
                execute_promise(promise)
                assert_equal [0, 1], order
            end
            it "executes the step in the EE thread by default" do
                thread = nil
                promise = execution_engine.promise
                promise.before { thread = Thread.current }
                execute_promise(promise)
                assert_equal Thread.current, thread
            end
            it "allows to execute the step within a separate thread with the in_engine option" do
                thread = nil
                promise = execution_engine.promise
                promise.before(in_engine: false) { thread = Thread.current }
                execute_promise(promise)
                refute_equal Thread.current, thread
            end
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

            it "queues follow-up succes handlers" do
                p = execution_engine.promise { }
                order = Array.new
                p.on_success { order << 1 }
                p.on_success { order << 2 }
                p.execute
                execution_engine.join_all_waiting_work
                assert_equal [1, 2], order
            end

            it "passes the result of one handler to the next" do
                p = execution_engine.promise { [1, 2] }
                p.on_success { |a, b| recorder.called(a, b); [3, 4, 5] }
                p.then { |a, b, c| recorder.called(a, b, c); 6 }
                p.on_success { |a| recorder.called(a) }

                recorder.should_receive(:called).with(1, 2).once.ordered
                recorder.should_receive(:called).with(3, 4, 5).once.ordered
                recorder.should_receive(:called).with(6).once.ordered
                p.execute
                process_events_until { p.fulfilled? }
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
            it "calls its block if the promise is rejected from within the thread pool" do
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

            it "passes the exception to the error handler" do
                error_m = Class.new(RuntimeError)
                p = execution_engine.promise { raise error_m }
                p.on_error   { |e| recorder.error(e) }
                recorder.should_receive(:error).with(error_m).once
                p.execute
                execution_engine.join_all_waiting_work
            end

            it "passes the exception object to all error handlers" do
                error_m = Class.new(RuntimeError)
                p = execution_engine.promise { raise error_m }
                p.on_error   { |e| recorder.error(e); Object.new }
                p.on_error   { |e| recorder.error(e); Object.new }
                recorder.should_receive(:error).with(error_m).twice
                p.execute
                execution_engine.join_all_waiting_work
            end

            it "reports the exception in the promise's #reason" do
                error_m = Class.new(RuntimeError)
                p = execution_engine.promise { raise error_m }
                p.on_error   { |e| recorder.error(e) }
                recorder.should_receive(:error).with(error_m).once
                p.execute
                execution_engine.join_all_waiting_work
                assert_kind_of error_m, p.reason
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
        
        describe "#has_error_handler?" do
            it "returns false if there are no error handlers" do
                p = execution_engine.promise { raise "TEST" }
                refute p.has_error_handler?
            end
            it "returns true if there is an error handler" do
                p = execution_engine.promise { raise "TEST" }
                p.on_error { }
                assert p.has_error_handler?
            end
        end

        describe "#value" do
            it "raises if the promise is not finished" do
                p = execution_engine.promise { }
                assert_raises(Promise::NotComplete) { p.value }
            end
            it "returns nil if the promise is rejected" do
                error_m = Class.new(RuntimeError)
                p = execution_engine.promise { raise error_m }
                p.on_error { } # to avoid raising in #join_all_waiting_work
                p.execute
                execution_engine.join_all_waiting_work
                assert_nil p.value
            end
            it "returns the last success handler result if the promise is finished" do
                result = flexmock
                p = execution_engine.promise { result }
                p.execute
                execution_engine.join_all_waiting_work
                assert_equal result, p.value
            end
        end

        describe "#value!" do
            it "raises if the promise is not finished" do
                p = execution_engine.promise { }
                assert_raises(Promise::NotComplete) { p.value! }
            end
            it "raises with the reason if the promise has been rejected" do
                error_m = Class.new(RuntimeError)
                p = execution_engine.promise { raise error_m }
                p.on_error { } # to avoid raising in #join_all_waiting_work
                p.execute
                execution_engine.join_all_waiting_work
                assert_raises(error_m) { p.value! }
            end
            it "returns the last success handler result if the promise is finished" do
                result = flexmock
                p = execution_engine.promise { result }
                p.execute
                execution_engine.join_all_waiting_work
                assert_equal result, p.value!
            end
        end

        describe "#execute" do
            it "schedules the promise" do
                p = execution_engine.promise { }
                p.execute
                assert p.pending?
            end
            it "returns self" do
                p = execution_engine.promise { }
                assert_same p, p.execute
            end
        end
    end
end
