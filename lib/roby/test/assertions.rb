module Roby
    module Test
        module Assertions
            def assert_adds_roby_localized_error(matcher)
                matcher = matcher.match
                errors = plan.execution_engine.gather_errors do
                    yield
                end

                errors = errors.map(&:exception)
                assert !errors.empty?, "expected to have added a LocalizedError, but got none"
                errors.each do |e|
                    assert_exception_can_be_pretty_printed(e)
                end
                if matched_e = errors.find { |e| matcher === e }
                    return matched_e
                elsif errors.empty?
                    flunk "block was expected to add an error matching #{matcher}, but did not"
                else
                    raise SynchronousEventProcessingMultipleErrors.new(errors)
                end
            end

            def assert_exception_can_be_pretty_printed(e)
                PP.pp(e, "") # verify that the exception can be pretty-printed, all Roby exceptions should
            end

            def assert_original_error(klass, localized_error_type = LocalizedError)
                old_level = Roby.logger.level
                Roby.logger.level = Logger::FATAL

                begin
                    yield
                rescue Exception => e
                    assert_kind_of(localized_error_type, e)
                    assert_respond_to(e, :error)
                    assert_kind_of(klass, e.error)
                end
            ensure
                Roby.logger.level = old_level
            end

            # Exception raised in the block of assert_doesnt_timeout when the timeout
            # is reached
            class FailedTimeout < RuntimeError; end

            # Checks that the given block returns within +seconds+ seconds
            def assert_doesnt_timeout(seconds, message = "watchdog #{seconds} failed")
                watched_thread = Thread.current
                watchdog = Thread.new do
                    sleep(seconds)
                    watched_thread.raise FailedTimeout
                end

                assert_block(message) do
                    begin
                        yield
                        true
                    rescue FailedTimeout
                    ensure
                        watchdog.kill
                        watchdog.join
                    end
                end
            end

	    # Wait for events to be emitted, or for some events to not be
            # emitted
            #
            # It will fail if all waited-for events become unreachable
            #
            # If a block is given, it is called after the checks are put in
            # place. This is required if the code in the block causes the
            # positive/negative events to be emitted
	    #
	    # @example test a task failure
	    #	assert_event_emission(task.fail_event) do
	    #	    task.start!
	    #	end
            #
            # @param [Array<EventGenerator>] positive the set of events whose
            #   emission we are waiting for
            # @param [Array<EventGenerator>] negative the set of events whose
            #   emission will cause the assertion to fail
            # @param [String] msg assertion failure message
            # @param [Float] timeout timeout in seconds after which the
            #   assertion fails if none of the positive events got emitted
            def assert_event_emission(positive = [], negative = [], msg = nil, timeout = 5, &block)
                error, result, unreachability_reason = watch_events(positive, negative, timeout, &block)

                if error
                    if !unreachability_reason.empty?
                        msg = format_unreachability_message(unreachability_reason)
                        flunk("all positive events are unreachable for the following reason:\n  #{msg}")
                    elsif msg
                        flunk("#{msg} failed: #{result}")
                    else
                        flunk(result)
                    end
                end
            end

            def watch_events(positive, negative, timeout, &block)
                if execution_engine.running?
                    raise NotImplementedError, "using running engines in tests is not supported anymore"
                end

                positive = Array[*(positive || [])].to_set
                negative = Array[*(negative || [])].to_set
                if positive.empty? && negative.empty? && !block
                    raise ArgumentError, "neither a block nor a set of positive or negative events have been given"
                end

		control_priority do
                    execution_engine.waiting_threads << Thread.current

                    unreachability_reason = Set.new
                    result_queue = Queue.new

                    execution_engine.execute do
                        if positive.empty? && negative.empty?
                            positive, negative = yield
                            positive = Array[*(positive || [])].to_set
                            negative = Array[*(negative || [])].to_set
                            if positive.empty? && negative.empty?
                                raise ArgumentError, "#{block} returned no events to watch"
                            end
                        elsif block_given?
                            yield
                        end

                        error, result = Test.event_watch_result(positive, negative)
                        if !error.nil?
                            result_queue.push([error, result])
                        else
                            positive.each do |ev|
                                ev.if_unreachable(cancel_at_emission: true) do |reason, event|
                                    unreachability_reason << [event, reason]
                                end
                            end
                            Test.watched_events << [result_queue, positive, negative, Time.now + timeout]
                        end
                    end

                    begin
                        while result_queue.empty?
                            process_events
                            sleep(0.05)
                        end
                        error, result = result_queue.pop
                    ensure
                        Test.watched_events.delete_if { |_, q, _| q == result_queue }
                    end
                    return error, result, unreachability_reason
		end
            ensure
                execution_engine.waiting_threads.delete(Thread.current)
            end

            def format_unreachability_message(unreachability_reason)
                msg = unreachability_reason.map do |ev, reason|
                    if reason.kind_of?(Exception)
                        Roby.format_exception(reason).join("\n")
                    elsif reason.respond_to?(:context)
                        context = if reason.context
                                      Roby.format_exception(reason.context).join("\n")
                                  end
                        "the emission of #{reason}#{context}"
                    end
                end
                msg.join("\n  ")
            end

            # Asserts that the given task is going to be added to the quarantine
            def assert_task_quarantined(task, timeout: 5)
                yield
                while !task.plan.quarantined_task?(task) && (Time.now - start) < timeout
                    task.plan.execution_engine.process_events
                end
            end

            # @deprecated use #assert_event_emission instead
	    def assert_any_event(positive = [], negative = [], msg = nil, timeout = 5, &block)
                Roby.warn_deprecated "#assert_any_event is deprecated, use #assert_event_emission instead"
                assert_event_emission(positive, negative, msg, timeout, &block)
	    end

            # @deprecated use #assert_event_becomes_unreachable instead
            def assert_becomes_unreachable(*args, &block)
                Roby.warn_deprecated "#assert_becomes_unreachable is deprecated, use #assert_event_becomes_unreachable instead"
                assert_event_becomes_unreachable(*args, &block)
            end

            # Verifies that the provided event becomes unreachable within a
            # certain time frame
            #
            # @param [EventGenerator] event
            # @param [Float] timeout in seconds
            # @yield a block of code that performs the action that should turn
            #   the event into unreachable
            def assert_event_becomes_unreachable(event, timeout = 5, &block)
                old_level = Roby.logger.level
                Roby.logger.level = Logger::FATAL
                error, message, unreachability_reason = watch_events(event, [], timeout, &block)
                if error = unreachability_reason.find { |ev, _| ev == event }
                    return
                end
                if !error
                    flunk("event has been emitted")
                else
                    msg = if !unreachability_reason.empty?
                              format_unreachability_message(unreachability_reason)
                          else
                              message
                          end
                    flunk("the following error happened before #{event} became unreachable:\n #{msg}")
                end
            ensure
                Roby.logger.level = old_level
            end

            def assert_child_of(parent, child, relation, *info)
                assert_same parent.relation_graphs, child.relation_graphs, "#{parent} and #{child} cannot be related as they are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                assert graph.has_vertex?(parent), "#{parent} and #{child} canot be related in #{relation} as the former is not in the graph"
                assert graph.has_vertex?(child),  "#{parent} and #{child} canot be related in #{relation} as the latter is not in the graph"
                assert parent.child_object?(child, relation), "#{child} is not a child of #{parent} in #{relation}"
                if !info.empty?
                    assert_equal info.first, parent[child, relation], "info differs"
                end
            end

            def refute_child_of(parent, child, relation)
                assert_same parent.relation_graphs, child.relation_graphs, "#{parent} and #{child} cannot be related as they are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                refute(graph.has_vertex?(parent) && graph.has_vertex?(child) && parent.child_object?(child, relation))
            end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task, *args)
		control_priority do
		    if !task.kind_of?(Roby::Task)
			execution_engine.execute do
			    plan.add_mission(task = planner.send(task, *args))
			end
		    end

		    assert_event_emission([task.event(:success)], [], nil) do
			plan.add_permanent(task)
			task.start! if task.pending?
			yield if block_given?
		    end
		end
	    end

	    def control_priority
                if !execution_engine.thread
                    return yield
                end

		old_priority = Thread.current.priority 
		Thread.current.priority = execution_engine.thread.priority + 1

		yield
	    ensure
		Thread.current.priority = old_priority if old_priority
	    end

	    # This assertion fails if the relative error between +found+ and
	    # +expected+is more than +error+
	    def assert_relative_error(expected, found, error, msg = "")
		if expected == 0
		    assert_in_delta(0, found, error, "comparing #{found} to #{expected} in #{msg}")
		else
		    assert_in_delta(0, (found - expected) / expected, error, "comparing #{found} to #{expected} in #{msg}")
		end
	    end

	    # This assertion fails if +found+ and +expected+ are more than +dl+
	    # meters apart in the x, y and z coordinates, or +dt+ radians apart
	    # in angles
	    def assert_same_position(expected, found, dl = 0.01, dt = 0.01, msg = "")
		assert_relative_error(expected.x, found.x, dl, msg)
		assert_relative_error(expected.y, found.y, dl, msg)
		assert_relative_error(expected.z, found.z, dl, msg)
		assert_relative_error(expected.yaw, found.yaw, dt, msg)
		assert_relative_error(expected.pitch, found.pitch, dt, msg)
		assert_relative_error(expected.roll, found.roll, dt, msg)
	    end
        end
    end
end


