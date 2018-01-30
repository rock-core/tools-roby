# List of backports waiting to be accepted in the backports gem

class Hash
    # Defined in 2.4.0
    def match?(string, pos = 0)
        !match(string, pos).nil?
    end unless Hash.method_defined?(:match?)
end
