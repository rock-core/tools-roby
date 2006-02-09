BASE_TEST_DIR=File.expand_path(File.dirname(__FILE__))
$LOAD_PATH.unshift BASE_TEST_DIR
$LOAD_PATH.unshift File.expand_path("../lib", File.dirname(__FILE__))

path=ENV['PATH'].split(':')
pkg_config_path=ENV['PKG_CONFIG_PATH'].split(':')

Dir.glob("#{BASE_TEST_DIR}/prefix.*") do |p|
    path << "#{p}/bin"
    pkg_config_path << "#{p}/lib/pkgconfig"
end
ENV['PATH'] = path.join(':')
ENV['PKG_CONFIG_PATH'] = pkg_config_path.join(':')

module Test::Unit::Assertions
    class FailedTimeout < Exception; end
    def assert_doesnt_timeout(seconds)
        watched_thread = Thread.current
        watchdog = Thread.new do
            sleep(seconds)
            watched_thread.raise FailedTimeout
        end

        begin
            yield
            watchdog.kill
        rescue FailedTimeout
            flunk("watchdog #{seconds} failed")
        end
    end
end


