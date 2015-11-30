require 'roby/test/self'
require 'roby/tasks/external_process'

class TC_Tasks_ExternalProcess < Minitest::Test 
    MOCKUP = File.expand_path(
        File.join("..", "mockups", "external_process"),
        File.dirname(__FILE__))

    class MockupTask < Roby::Tasks::ExternalProcess
        event :stop do |context|
            FileUtils.touch "/tmp/external_process_mockup_stop"
        end
    end

    def test_nominal
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--no-output"]))
        assert_event_emission(task.success_event) do
            task.start!
        end
    end

    def test_nominal_array_with_one_element
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: [MOCKUP]))
        task.redirect_output "mockup-%p.log"
        assert_event_emission(task.success_event) do
            task.start!
        end
    ensure
        FileUtils.rm_f "mockup-#{task.pid}.log"
    end

    def test_nominal_no_array
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: MOCKUP))
        task.redirect_output "mockup-%p.log"
        assert_event_emission(task.success_event) do
            task.start!
        end
    ensure
        FileUtils.rm_f "mockup-#{task.pid}.log"
    end

    def test_inexistent_program
        Roby.logger.level = Logger::FATAL
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: ['does_not_exist', "--error"]))
        e = assert_raises(RuntimeError) do
            task.start!
        end
        assert_match /provided command does not exist/, e.original_exception.message
        assert task.failed?
    end

    def test_failure
        Roby.logger.level = Logger::FATAL
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--error"]))
        assert_event_emission(task.failed_event) do
            task.start!
        end
        assert_equal 1, task.event(:failed).last.context.first.exitstatus
    end

    def test_signaling
        Roby.logger.level = Logger::FATAL
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--block"]))
        assert_event_emission(task.start_event) do
            task.start!
        end
        assert_event_emission(task.failed_event) do
            Process.kill 'KILL', task.pid
        end
        assert task.signaled?

        ev = task.signaled_event.last
        assert_equal 9, ev.context.first.termsig
    end

    def do_redirection(expected)
        plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: [MOCKUP]))
        yield(task)

        assert_event_emission(task.success_event) do
            task.start!
        end

        assert File.exists?("mockup-#{task.pid}.log")
        File.read("mockup-#{task.pid}.log")

    ensure
        FileUtils.rm_f "mockup-#{task.pid}.log"
    end

    def test_stdout_redirection
        do_redirection `#{MOCKUP}` do |task|
            task.redirect_output stdout: 'mockup-%p.log'
        end
    end

    def test_stderr_redirection
        do_redirection `#{MOCKUP}` do |task|
            task.command_line << "--stderr"
            task.redirect_output stderr: 'mockup-%p.log'
        end
    end

    def test_common_redirection
        output = do_redirection(nil) do |task|
            task.command_line << "--common"
            task.redirect_output 'mockup-%p.log'
        end


        expected = `#{MOCKUP} --common 2>&1`
        assert_equal expected, output
    end

    # Continuously start external processes in parallel. This is to stress test
    # the implementation against deadlocks and against bugs in the Ruby
    # interpreter (which led to the forked ruby to freeze completely).
    # def test_stress_test
    #     engine.run
    #     GC.stress = false

    #     count = 0
    #     tasks = []
    #     while true
    #         start_time = Time.now
    #         while !tasks.empty?
    #             engine.execute do
    #                 tasks.delete_if(&:finished?)
    #                 STDERR.puts "remaining tasks: #{tasks.size}"
    #                 if (Time.now - start_time) > 5
    #                     STDERR.puts "remaining tasks: #{tasks.map(&:pid)}"
    #                 end
    #             end
    #         end

    #         engine.execute do
    #             50.times do
    #                 plan.add_permanent(task = Tasks::ExternalProcess.new(command_line: [MOCKUP, "--no-output"]))
    #                 task.start!
    #                 tasks << task
    #                 count += 1
    #             end
    #             STDERR.puts(count)
    #         end
    #     end
    # end
end


