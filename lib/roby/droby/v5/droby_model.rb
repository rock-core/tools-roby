module Roby
    module DRoby
        module V5
            class DRobyModel
                attr_reader :name
                attr_reader :remote_siblings
                attr_reader :supermodel
                attr_reader :provided_models

                def initialize(name, remote_siblings, supermodel, provided_models)
                    @name, @remote_siblings, @supermodel, @provided_models =
                        name, remote_siblings, supermodel, provided_models
                end

                def proxy(peer)
                    # Ensure that the peer-local info of related models gets
                    # registered, no matter what.
                    if supermodel
                        @unmarshalled_supermodel = peer.local_model(supermodel)
                    end
                    @unmarshalled_provided_models = @provided_models.map { |m| peer.local_model(m) }

                    if local_m = peer.find_local_model(self)
                        # Ensures that the supermodel(s) are registered
                        return local_m
                    elsif !supermodel
                        raise NoLocalObject, "#{name}, at the root of a model hierarchy, was expected to be explicitely registered but is not"
                    else
                        create_new_proxy_model(peer)
                    end
                end

                def create_new_proxy_model(peer)
                    local_model = @unmarshalled_supermodel.new_submodel(name: name || "#{@unmarshalled_supermodel.name}#")
                    peer.register_model(local_model, remote_siblings)
                    local_model
                end

                def update(peer, local_object, fresh_proxy: false)
                    @unmarshalled_provided_models ||= @provided_models.map { |m| peer.local_model(m) }
                    @unmarshalled_provided_models.each do |local_m|
                        if !(local_object <= local_m)
                            local_object.provides local_m
                        end
                    end
                end

                def self.dump_supermodel(peer, model)
                    s = model.supermodel
                    if s.kind_of?(ModelDumper)
                        peer.dump_model(s)
                    end
                end

                def self.dump_provided_models_of(peer, model)
                    provided_models_of(model).map do |m|
                        peer.dump_model(m)
                    end
                end

                def self.provided_models_of(model)
                    super_m = model.supermodel
                    provided_m = Array.new
                    model.ancestors.each do |m|
                        if m == super_m
                            break
                        elsif (m != model) && m.kind_of?(ModelDumper)
                            provided_m << m
                        end
                    end
                    provided_m
                end
            end
        end
    end
end


