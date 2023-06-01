# frozen_string_literal: true

require "roby/test/minitest_reporter"

module Roby
    module Test
        # Plugin for minitest to set it up as we need
        #
        # A 'plugin' must have its name registered in Minitest.extensions From
        # there on, some methods - if they are made available as singleton
        # methods on the Minitest module - will be called.
        #
        # This module implement the methods we need to tune minitest as we need
        # it. Just call MinitestPlugin.register before Minitest.run gets called
        module MinitestPlugin
            def plugin_roby_init(options)
                reporter = Minitest.reporter
                reporter.reporters.shift
                reporter.reporters.unshift(
                    MinitestReporter.new(options[:io], options)
                )
            end

            # Make this plugin active on Minitest
            #
            # Must be called before Minitest.run
            def self.register
                Minitest.extensions << "roby"
                Minitest.extend MinitestPlugin
            end
        end
    end
end
