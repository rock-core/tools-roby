# frozen_string_literal: true

require "rack/test"
require "rest-client"

module Roby
    module Interface
        module REST
            # Test helpers to interact with a REST API embedded in a Roby app
            #
            # It provides a Roby-compatible integration with Rack::Test. You only
            # need to overload the {#rest_api} method to return your Grape API class
            #
            # You cannot use this with a describe ... block (yet). Instead, do
            #
            #   class TESTNAME < Syskit::Test::Spec
            #       include Roby::Interface::REST::Test
            #       # rest of the tests
            #   end
            #
            # Note that you can use describe block within the test class
            #
            # Whenever you call an endpoint that acts on the execution engine (e.g.
            # emits an event), wrap it in an execute { } block
            module Test
                include Rack::Test::Methods

                def rest_api
                    raise NotImplementedError, "implement #rest_api in your test "\
                                               "to return the REST API"
                end

                # The {Helpers#roby_storage} object that is being accessed by the API
                def roby_storage
                    @roby_storage ||= {}
                end

                # @api private
                #
                # Overloaded from Rack::Test to inject the app and plan
                # and make them available to the API
                def build_rack_mock_session(roby_execute: false)
                    interface = Roby::Interface::Interface.new(app)
                    actual_api =
                        Roby::Interface::REST::Server
                        .attach_api_to_interface(
                            rest_api, interface, roby_storage,
                            roby_execute: roby_execute
                        )
                    Rack::MockSession.new(actual_api)
                end
            end
        end
    end
end
