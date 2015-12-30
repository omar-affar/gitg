class Gitg < Formula
  desc "git viewer"
  homepage "https://projects.gnome.org/gitg/"
  head "https://git.gnome.org/browse/gitg.git"

  depends_on "autoconf" => :build
  depends_on "automake" => :build
  depends_on "pkg-config" => :build
  depends_on "intltool" => :build
  depends_on "libtool" => :build
  depends_on "vala" => :build
  depends_on "gettext"
  depends_on "glib"
  depends_on "shared-mime-info"
  depends_on "gnome/gitg/gtk+3" => "with-quartz-relocation"
  depends_on "gnome/gitg/gtksourceview3"
  depends_on "gnome/gitg/libsoup"
  depends_on "gnome/gitg/libsecret"
  depends_on "gnome/gitg/libpeas"
  depends_on "gnome/gitg/gtkspell3"
  depends_on "gnome/gitg/libgee"
  depends_on "gnome/gitg/gsettings-desktop-schemas"
  depends_on "gnome/gitg/libgit2-glib"
  depends_on "gnome/gitg/gnome-icon-theme"

  def install
    system "./autogen.sh", "--disable-dependency-tracking",
                           "--disable-maintainer-mode",
                           "--disable-schemas-compile",
                           "--prefix=#{prefix}"
    
    ENV.prepend_path "XDG_DATA_DIRS", "#{HOMEBREW_PREFIX}/share"

    ENV.prepend_path "GIRDIR", "#{HOMEBREW_PREFIX}/share/gir-1.0"
    ENV.prepend_path "VAPIDIR", "#{HOMEBREW_PREFIX}/share/vala/vapi"
    ENV.prepend_path "VAPIDIR", "#{HOMEBREW_PREFIX}/share/vala-0.30/vapi"

    system "make", "install"
  end

  def post_install
    system "#{Formula["glib"].opt_bin}/glib-compile-schemas", "#{HOMEBREW_PREFIX}/share/glib-2.0/schemas"
  end
end
