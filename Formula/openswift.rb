class Openswift < Formula
  desc "macOS app accelerator - control process speed via DYLD injection"
  homepage "https://github.com/JiangWanZhengChouYv/OpenSwift"
  url "https://github.com/JiangWanZhengChouYv/OpenSwift/releases/download/v0.1.0/OpenSwift-v0.1.0.zip"
  version "0.1.0"
  sha256 "c91fc35f3b1ec788612e83d79cc4dbd271a930c7c3114c94bcf4df71049fb23f"
  
  def install
    bin.install "openswift"
  end

  test do
    system "#{bin}/openswift", "--help"
  end
end
