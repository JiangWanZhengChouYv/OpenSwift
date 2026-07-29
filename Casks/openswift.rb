cask "openswift" do
  version "1.0.0"
  sha256 "412c8ad13e80c8eca56d3c8ca5cdfd2302d512e0c01586dc35b61e21088c7ad2"

  url "https://github.com/JiangWanZhengChouYv/OpenSwift/releases/download/v#{version}/OpenSwift-v#{version}.zip"
  name "OpenSwift"
  desc "macOS app accelerator - control process speed via DYLD injection"
  homepage "https://github.com/JiangWanZhengChouYv/OpenSwift"

  depends_on macos: :ventura

  app "OpenSwift.app"
end
