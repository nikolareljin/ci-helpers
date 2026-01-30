class @BREW_FORMULA_CLASS@ < Formula
  desc "@BREW_DESC@"
  homepage "@BREW_HOMEPAGE@"
  url "@BREW_URL@"
  version "@APP_VERSION@"
  sha256 "@BREW_SHA256@"
  license "@BREW_LICENSE@"

@BREW_DEPENDS_LINES@
  def install
    @BREW_INSTALL_CMD@
  end

  test do
    @BREW_TEST_CMD@
  end
end
