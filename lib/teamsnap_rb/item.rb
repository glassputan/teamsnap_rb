module TeamsnapRb
  class Item
    def initialize(item, auth)
      self.auth = auth
      self.item = item
    end

    def links
      @links ||= LinksProxy.new(item.links, auth)
    end

    def href
      item.href
    end

    def method_missing(method, *args)
      if datum = item.data.find { |d| d.name == method.to_s }
        unless instance_variable_get("@#{method}_datum")
          instance_variable_set("@#{method}_datum", datum.value)
        end

        instance_variable_get("@#{method}_datum")
      else
        super
      end
    end

    def respond_to?(method)
      if item.data.find { |d| d.name == method.to_s }
        true
      else
        false
      end
    end

    private

    attr_accessor :item, :auth
  end
end