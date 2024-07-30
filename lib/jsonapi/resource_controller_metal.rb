module JSONAPI
  class ResourceControllerMetal < ActionController::Metal
    MODULES = [
      AbstractController::Rendering,
      ActionController::Rendering,
      ActionController::Renderers::All,
      ActionController::StrongParameters,
      Gem::Requirement.new('< 6.1').satisfied_by?(ActionPack.gem_version) ? ActionController::ForceSSL : nil,
      ActionController::Instrumentation,
      JSONAPI::ActsAsResourceController
    ].compact.freeze

    MODULES.each do |mod|
      include mod
    end
  end
end