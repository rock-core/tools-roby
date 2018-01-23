module Roby
    module Interface
        module REST
            # The endpoints
            class API < Grape::API
                version 'v1', using: :header, vendor: :syskit
                format :json

                helpers Helpers

                params do
                    optional :value, type: Integer, default: 20
                end
                get 'ping' do
                    if !interface
                        error!({error: 'Internal Error', details: 'no attached Roby interface'}, 500)
                    end
                    params[:value]
                end
            end
        end
    end
end

