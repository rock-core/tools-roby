$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/external_process_task'
require 'roby/test/tasks/simple_task'
require 'roby/test/tasks/empty_task'

class TC_ThreadTask < Test::Unit::TestCase 
    include Roby::Test

    MOCKUP = File.expand_path(
        File.join("..", "mockups", "external_process"),
        File.dirname(__FILE__))

    class MockupTask < Roby::ExternalProcessTask
        event :stop do
            FileUtils.touch "/tmp/external_process_mockup_stop"
        end
    end

    def assert_polling_successful(timeout, sleep = 0.05)
        now = Time.now
        while (Time.now - now) < timeout
            if yield
                return
            end
        end
        flunk "reached timeout"
    end

    def test_nominal
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => [MOCKUP, "--no-output"]))
        engine.run
        engine.once { task.start! }

        assert_polling_successful(5) { task.success? }
    end

    def test_nominal_array_with_one_element
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => [MOCKUP]))
        engine.run
        engine.once { task.start! }

        assert_polling_successful(5) { task.success? }
    end

    def test_nominal_no_array
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => MOCKUP))
        engine.run
        engine.once { task.start! }

        assert_polling_successful(5) { task.success? }
    end

    def test_inexistent_program
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => ['does_not_exist', "--error"]))
        engine.run
        engine.once { task.start! }

        assert_polling_successful(5) { task.failed? }
        assert_equal 1, task.event(:failed).last.context.first.exitstatus
    end

    def test_failure
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => [MOCKUP, "--error"]))
        engine.run
        engine.once { task.start! }

        assert_polling_successful(5) { task.failed? }
        assert_equal 1, task.event(:failed).last.context.first.exitstatus
    end

    def test_signaling
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => [MOCKUP, "--block"]))
        engine.run
        engine.once { task.start! }
        assert_polling_successful(5) { task.running? }

        Process.kill 'KILL', task.pid
        assert_polling_successful(5) { task.failed? }
        assert task.event(:signaled).happened?

        ev = task.event(:signaled).last
        assert_equal 9, ev.context.first.termsig
    end

    def do_redirection(expected)
        plan.add_permanent(task = ExternalProcessTask.new(:command_line => [MOCKUP]))
        yield(task)
        engine.run
        engine.once { task.start! }

        assert_polling_successful(5) { task.success? }

        assert File.exists?("mockup-#{task.pid}.log")
        File.read("mockup-#{task.pid}.log")

    ensure
        FileUtils.rm_f "mockup-#{task.pid}.log"
    end

    def test_stdout_redirection
        do_redirection `#{MOCKUP}` do |task|
            task.redirect_output :stdout => 'mockup-%p.log'
        end
    end

    def test_stderr_redirection
        do_redirection `#{MOCKUP}` do |task|
            task.command_line << "--stderr"
            task.redirect_output :stderr => 'mockup-%p.log'
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
end


