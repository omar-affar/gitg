/*
 * This file is part of gitg
 *
 * Copyright (C) 2016 - Jesse van den Kieboom
 *
 * gitg is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * gitg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with gitg. If not, see <http://www.gnu.org/licenses/>.
 */

[GtkTemplate (ui = "/org/gnome/gitg/ui/gitg-diff-view-file-renderer-text.ui")]
class Gitg.DiffViewFileRendererText : Gtk.SourceView, DiffSelectable, DiffViewFileRenderer
{
	private enum RegionType
	{
		ADDED,
		REMOVED,
		CONTEXT
	}

	private struct Region
	{
		public RegionType type;
		public int buffer_line_start;
		public int source_line_start;
		public int length;
	}

	public uint added { get; set; }
	public uint removed { get; set; }

	private int64 d_doffset;

	private Gee.HashMap<int, PatchSet.Patch?> d_lines;

	private DiffViewFileSelectable d_selectable;
	private DiffViewLinesRenderer d_old_lines;
	private DiffViewLinesRenderer d_new_lines;
	private DiffViewLinesRenderer d_sym_lines;

	private bool d_highlight;

	private Cancellable? d_higlight_cancellable;
	private Gtk.SourceBuffer? d_old_highlight_buffer;
	private Gtk.SourceBuffer? d_new_highlight_buffer;
	private bool d_old_highlight_ready;
	private bool d_new_highlight_ready;

	private Region[] d_regions;
	private bool d_constructed;

	public bool new_is_workdir { get; construct set; }

	public bool wrap_lines
	{
		get { return this.wrap_mode != Gtk.WrapMode.NONE; }
		set
		{
			if (value)
			{
				this.wrap_mode = Gtk.WrapMode.WORD_CHAR;
			}
			else
			{
				this.wrap_mode = Gtk.WrapMode.NONE;
			}
		}
	}

	public new int tab_width
	{ 
		get { return (int)get_tab_width(); }
		set { set_tab_width((uint)value); }
	}

	public int maxlines { get; set; }
	public Ggit.DiffDelta? delta { get; construct set; }
	public Repository repository { get; construct set; }

	public bool highlight
	{
		get { return d_highlight; }

		construct set
		{
			d_highlight = value;
			update_highlight();
		}

		default = true;
	}
	
	private bool d_has_selection;

	public bool has_selection
	{
		get { return d_has_selection; }
	}
	
	public bool can_select { get; construct set; }

	public PatchSet selection
	{
		owned get
		{
			var ret = new PatchSet();

			ret.filename = delta.get_new_file().get_path();

			var patches = new PatchSet.Patch[0];

			if (!can_select)
			{
				return ret;
			}

			var selected = d_selectable.selected_lines;

			for (var i = 0; i < selected.length; i++)
			{
				var line = selected[i];
				var pset = d_lines[line];

				if (i == 0)
				{
					patches += pset;
					continue;
				}
				
				var last = patches[patches.length - 1];

				if (last.new_offset + last.length == pset.new_offset &&
				    last.type == pset.type)
				{
					last.length += pset.length;
					patches[patches.length - 1] = last;
				}
				else
				{
					patches += pset;
				}
			}

			ret.patches = patches;
			return ret;
		}
	}

	public DiffViewFileRendererText(Repository repository, Ggit.DiffDelta delta, bool new_is_workdir, bool can_select)
	{
		Object(repository: repository, new_is_workdir: new_is_workdir, delta: delta, can_select: can_select);
	}

	construct
	{
		var gutter = this.get_gutter(Gtk.TextWindowType.LEFT);

		d_old_lines = new DiffViewLinesRenderer(DiffViewLinesRenderer.Style.OLD);
		d_new_lines = new DiffViewLinesRenderer(DiffViewLinesRenderer.Style.NEW);
		d_sym_lines = new DiffViewLinesRenderer(DiffViewLinesRenderer.Style.SYMBOL);

		this.bind_property("maxlines", d_old_lines, "maxlines", BindingFlags.DEFAULT | BindingFlags.SYNC_CREATE);
		this.bind_property("maxlines", d_new_lines, "maxlines", BindingFlags.DEFAULT | BindingFlags.SYNC_CREATE);

		d_old_lines.xpad = 8;
		d_new_lines.xpad = 8;
		d_sym_lines.xpad = 6;

		gutter.insert(d_old_lines, 0);
		gutter.insert(d_new_lines, 1);
		gutter.insert(d_sym_lines, 2);

		this.set_border_window_size(Gtk.TextWindowType.TOP, 1);

		var settings = Gtk.Settings.get_default();
		settings.notify["gtk-application-prefer-dark-theme"].connect(update_theme);

		update_theme();

		if (can_select)
		{
			d_selectable = new DiffViewFileSelectable(this);

			d_selectable.notify["has-selection"].connect(() => {
				d_has_selection = d_selectable.has_selection;
				notify_property("has-selection");
			});
		}

		d_lines = new Gee.HashMap<int, PatchSet.Patch?>();
	}

	protected override void dispose()
	{
		base.dispose();

		if (d_higlight_cancellable != null)
		{
			d_higlight_cancellable.cancel();
			d_higlight_cancellable = null;
		}
	}

	private void update_highlight()
	{
		if (!d_constructed)
		{
			return;
		}

		if (d_higlight_cancellable != null)
		{
			d_higlight_cancellable.cancel();
			d_higlight_cancellable = null;
		}

		d_old_highlight_buffer = null;
		d_new_highlight_buffer = null;

		d_old_highlight_ready = false;
		d_new_highlight_ready = false;

		if (highlight && repository != null && delta != null)
		{
			var cancellable = new Cancellable();
			d_higlight_cancellable = cancellable;

			init_highlighting_buffer.begin(delta.get_old_file(), false, cancellable, (obj, res) => {
				var buffer = init_highlighting_buffer.end(res);

				if (!cancellable.is_cancelled())
				{
					d_old_highlight_buffer = buffer;
					d_old_highlight_ready = true;

					update_highlighting_ready();
				}
			});

			init_highlighting_buffer.begin(delta.get_new_file(), new_is_workdir, cancellable, (obj, res) => {
				var buffer = init_highlighting_buffer.end(res);

				if (!cancellable.is_cancelled())
				{
					d_new_highlight_buffer = buffer;
					d_new_highlight_ready = true;

					update_highlighting_ready();
				}
			});
		}
		else
		{
			update_highlighting_ready();
		}
	}

	private async Gtk.SourceBuffer? init_highlighting_buffer(Ggit.DiffFile file, bool from_workdir, Cancellable cancellable)
	{
		var id = file.get_oid();
		var path = file.get_path();

		if ((id.is_zero() && !from_workdir) || (path == null && from_workdir))
		{
			return null;
		}

		var sfile = new Gtk.SourceFile();
		sfile.location = repository.get_workdir().get_child(path);

		var basename = sfile.location.get_basename();
		uint8[] content;

		if (!from_workdir)
		{
			Ggit.Blob blob;

			try
			{
				blob = repository.lookup<Ggit.Blob>(id);
			}
			catch
			{
				return null;
			}

			content = blob.get_raw_content();
		}
		else
		{
			// Try to read from disk
			try
			{
				string etag;

				// Read it all into a buffer so we can guess the content type from
				// it. This isn't really nice, but it's simple.
				yield sfile.location.load_contents_async(cancellable, out content, out etag);
			}
			catch
			{
				return null;
			}
		}

		bool uncertain;
		var content_type = GLib.ContentType.guess(basename, content, out uncertain);

		var bytes = new Bytes(content);
		var stream = new GLib.MemoryInputStream.from_bytes(bytes);

		var manager = Gtk.SourceLanguageManager.get_default();
		var language = manager.guess_language(basename, content_type);

		if (language == null)
		{
			return null;
		}

		var buffer = new Gtk.SourceBuffer(this.buffer.tag_table);

		var style_scheme_manager = Gtk.SourceStyleSchemeManager.get_default();

		buffer.language = language;
		buffer.highlight_syntax = true;
		buffer.style_scheme = style_scheme_manager.get_scheme("classic");

		var loader = new Gtk.SourceFileLoader.from_stream(buffer, sfile, stream);

		try
		{
			yield loader.load_async(GLib.Priority.LOW, cancellable, null);
		}
		catch (Error e)
		{
			if (!cancellable.is_cancelled())
			{
				stderr.printf(@"ERROR: failed to load $(file.get_path()) for highlighting: $(e.message)\n");
			}

			return null;
		}

		return buffer;
	}

	private void update_highlighting_ready()
	{
		if (!d_old_highlight_ready && !d_new_highlight_ready)
		{
			// Remove highlights
			return;
		}
		else if (!d_old_highlight_ready || !d_new_highlight_ready)
		{
			// Both need to be loaded
			return;
		}

		var buffer = this.buffer;

		// Go over all the source chunks and match up to old/new buffer. Then,
		// apply the tags that are applied to the highlighted source buffers.
		foreach (var region in d_regions)
		{
			Gtk.SourceBuffer? source;

			if (region.type == RegionType.REMOVED)
			{
				source = d_old_highlight_buffer;
			}
			else
			{
				source = d_new_highlight_buffer;
			}

			if (source == null)
			{
				continue;
			}

			Gtk.TextIter buffer_iter, source_iter;

			buffer.get_iter_at_line(out buffer_iter, region.buffer_line_start);
			source.get_iter_at_line(out source_iter, region.source_line_start);

			var source_end_iter = source_iter;
			source_end_iter.forward_lines(region.length);

			source.ensure_highlight(source_iter, source_end_iter);

			var buffer_end_iter = buffer_iter;
			buffer_end_iter.forward_lines(region.length);

			var source_next_iter = source_iter;
			var tags = source_iter.get_tags();

			while (source_next_iter.forward_to_tag_toggle(null) && source_next_iter.compare(source_end_iter) < 0)
			{
				var buffer_next_iter = buffer_iter;
				buffer_next_iter.forward_chars(source_next_iter.get_offset() - source_iter.get_offset());

				foreach (var tag in tags)
				{
					buffer.apply_tag(tag, buffer_iter, buffer_next_iter);
				}

				source_iter = source_next_iter;
				buffer_iter = buffer_next_iter;

				tags = source_iter.get_tags();
			}

			foreach (var tag in tags)
			{
				buffer.apply_tag(tag, buffer_iter, buffer_end_iter);
			}
		}
	}

	protected override bool draw(Cairo.Context cr)
	{
		base.draw(cr);

		var win = this.get_window(Gtk.TextWindowType.LEFT);

		if (!Gtk.cairo_should_draw_window(cr, win))
		{
			return false;
		}

		var ctx = this.get_style_context();

		var old_lines_width = d_old_lines.size + d_old_lines.xpad * 2;
		var new_lines_width = d_new_lines.size + d_new_lines.xpad * 2;
		var sym_lines_width = d_sym_lines.size + d_sym_lines.xpad * 2;

		ctx.save();
		ctx.add_class("diff-lines-separator");
		ctx.render_frame(cr, 0, 0, old_lines_width, win.get_height());
		ctx.restore();

		ctx.save();
		ctx.add_class("diff-lines-gutter-border");
		ctx.render_frame(cr, old_lines_width + new_lines_width, 0, sym_lines_width, win.get_height());
		ctx.restore();
		
		return false;
	}

	private void update_theme()
	{
		var header_attributes = new Gtk.SourceMarkAttributes();
		var added_attributes = new Gtk.SourceMarkAttributes();
		var removed_attributes = new Gtk.SourceMarkAttributes();

		var settings = Gtk.Settings.get_default();
		var theme = Environment.get_variable("GTK_THEME");

		var dark = settings.gtk_application_prefer_dark_theme || (theme != null && theme.has_suffix(":dark"));

		if (dark)
		{
			header_attributes.background = Gdk.RGBA() { red = 136.0 / 255.0, green = 138.0 / 255.0, blue = 133.0 / 255.0, alpha = 1.0 };
			added_attributes.background = Gdk.RGBA() { red = 78.0 / 255.0, green = 154.0 / 255.0, blue = 6.0 / 255.0, alpha = 1.0 };
			removed_attributes.background = Gdk.RGBA() { red = 164.0 / 255.0, green = 0.0, blue = 0.0, alpha = 1.0 };
		}
		else
		{
			header_attributes.background = Gdk.RGBA() { red = 244.0 / 255.0, green = 247.0 / 255.0, blue = 251.0 / 255.0, alpha = 1.0 };
			added_attributes.background = Gdk.RGBA() { red = 220.0 / 255.0, green = 1.0, blue = 220.0 / 255.0, alpha = 1.0 };
			removed_attributes.background = Gdk.RGBA() { red = 1.0, green = 220.0 / 255.0, blue = 220.0 / 255.0, alpha = 1.0 };
		}

		this.set_mark_attributes("header", header_attributes, 0);
		this.set_mark_attributes("added", added_attributes, 0);
		this.set_mark_attributes("removed", removed_attributes, 0);
	}

	protected override void constructed()
	{
		base.constructed();

		d_constructed = true;
		update_highlight();
	}

	public void add_hunk(Ggit.DiffHunk hunk, Gee.ArrayList<Ggit.DiffLine> lines)
	{
		var buffer = this.buffer as Gtk.SourceBuffer;

		/* Diff hunk */
		var h = hunk.get_header();
		var pos = h.last_index_of("@@");

		if (pos >= 0)
		{
			h = h.substring(pos + 2).chug();
		}

		h = h.chomp();

		Gtk.TextIter iter;
		buffer.get_end_iter(out iter);

		if (!iter.is_start())
		{
			buffer.insert(ref iter, "\n", 1);
		}

		iter.set_line_offset(0);
		buffer.create_source_mark(null, "header", iter);

		var header = @"@@ -$(hunk.get_old_start()),$(hunk.get_old_lines()) +$(hunk.get_new_start()),$(hunk.get_new_lines()) @@ $h\n";
		buffer.insert(ref iter, header, -1);

		int buffer_line = iter.get_line();

		/* Diff Content */
		var content = new StringBuilder();

		var region = Region() {
			type = RegionType.CONTEXT,
			buffer_line_start = 0,
			source_line_start = 0,
			length = 0
		};

		this.freeze_notify();

		for (var i = 0; i < lines.size; i++)
		{
			var line = lines[i];
			var text = line.get_text();
			var added = false;
			var removed = false;
			var origin = line.get_origin();

			var rtype = RegionType.CONTEXT;

			switch (origin)
			{
				case Ggit.DiffLineType.ADDITION:
					added = true;
					this.added++;

					rtype = RegionType.ADDED;
					break;
				case Ggit.DiffLineType.DELETION:
					removed = true;
					this.removed++;

					rtype = RegionType.REMOVED;
					break;
				case Ggit.DiffLineType.CONTEXT_EOFNL:
				case Ggit.DiffLineType.ADD_EOFNL:
				case Ggit.DiffLineType.DEL_EOFNL:
					text = text.substring(1);
					break;
			}

			if (i == 0 || rtype != region.type)
			{
				if (i != 0)
				{
					d_regions += region;
				}

				int source_line_start;

				if (rtype == RegionType.REMOVED)
				{
					source_line_start = line.get_old_lineno() - 1;
				}
				else
				{
					source_line_start = line.get_new_lineno() - 1;
				}

				region = Region() {
					type = rtype,
					buffer_line_start = buffer_line,
					source_line_start = source_line_start,
					length = 0
				};
			}

			region.length++;

			if (added || removed)
			{
				var offset = (size_t)line.get_content_offset();
				var bytes = line.get_content();

				var pset = PatchSet.Patch() {
					type = added ? PatchSet.Type.ADD : PatchSet.Type.REMOVE,
					old_offset = offset,
					new_offset = offset,
					length = bytes.length
				};

				if (added)
				{
					pset.old_offset = (size_t)((int64)pset.old_offset - d_doffset);
				}
				else
				{
					pset.new_offset = (size_t)((int64)pset.new_offset + d_doffset);
				}

				d_lines[buffer_line] = pset;
				d_doffset += added ? (int64)bytes.length : -(int64)bytes.length;
			}

			if (i == lines.size - 1 && text.length > 0 && text[text.length - 1] == '\n')
			{
				text = text.slice(0, text.length - 1);
			}

			content.append(text);
			buffer_line++;
		}

		if (lines.size != 0)
		{
			d_regions += region;
		}

		int line_hunk_start = iter.get_line();

		buffer.insert(ref iter, (string)content.data, -1);

		d_old_lines.add_hunk(line_hunk_start, iter.get_line(), hunk, lines);
		d_new_lines.add_hunk(line_hunk_start, iter.get_line(), hunk, lines);
		d_sym_lines.add_hunk(line_hunk_start, iter.get_line(), hunk, lines);

		for (var i = 0; i < lines.size; i++)
		{
			var line = lines[i];
			string? category = null;

			switch (line.get_origin())
			{
				case Ggit.DiffLineType.ADDITION:
					category = "added";
					break;
				case Ggit.DiffLineType.DELETION:
					category = "removed";
					break;
			}

			if (category != null)
			{
				buffer.get_iter_at_line(out iter, line_hunk_start + i);
				buffer.create_source_mark(null, category, iter);
			}
		}

		this.thaw_notify();

		sensitive = true;
	}
}

// ex:ts=4 noet
