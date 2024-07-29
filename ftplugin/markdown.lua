local markview = require("markview");
local utils = require("markview.utils");

local ts_available, treesitter_parsers = pcall(require, "nvim-treesitter.parsers");
local function parser_installed(parser)
	return (ts_available and treesitter_parsers.has_parser(parser)) or
		(vim.treesitter.query.get(parser, "highlights"))
end

-- Check for requirements
if vim.fn.has("nvim-0.10") == 0 then
	vim.print("[ markview.nvim ] : Thie plugin is only available on version 0.10.0 and higher!");
	return;
elseif not parser_installed("markdown") then
	vim.print("[ markview.nvim ] : Treesitter parser for 'markdown' wasn't found!");
	return;
elseif not parser_installed("markdown_inline") then
	vim.print("[ markview.nvim ] : Treesitter parser for 'markdown_inline' wasn't found!");
	return;
end

if vim.islist(markview.configuration.buf_ignore) and vim.list_contains(markview.configuration.buf_ignore, vim.bo.buftype) then
	return
end

if vim.islist(markview.configuration.highlight_groups) then
	markview.add_hls(markview.configuration.highlight_groups)
end

local markview_augroup = vim.api.nvim_create_augroup("markview_buf_" .. vim.api.nvim_get_current_buf(), { clear = true });

vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
	buffer = vim.api.nvim_get_current_buf(),
	group = markview_augroup,

	callback = function (event)
		local buffer = event.buf;
		local windows = utils.find_attached_wins(event.buf);

		if not vim.list_contains(markview.attached_buffers, buffer) then
			table.insert(markview.attached_buffers, buffer);
			markview.attached_windows = vim.list_extend(markview.attached_windows, windows)
		end

		if markview.state.enable == false then
			-- Call the on_disable callback before exiting
			if not markview.configuration.callbacks or not markview.configuration.callbacks.on_disable then
				return;
			end

			for _, window in ipairs(windows) do
				pcall(markview.configuration.callbacks.on_disable, buffer, window);
			end

			return;
		end

		if markview.state.buf_states[buffer] == false then
			-- Call the on_disable callback before exiting
			-- Even if only the buffer is disabled
			if not markview.configuration.callbacks or not markview.configuration.callbacks.on_disable then
				return;
			end

			for _, window in ipairs(windows) do
				pcall(markview.configuration.callbacks.on_disable, buffer, window);
			end

			return;
		end

		markview.state.buf_states[buffer] = true;

		if vim.tbl_isempty(markview.global_options) then
			markview.global_options = {
				conceallevel = vim.o.conceallevel,
				concealcursor = vim.o.concealcursor
			}
		end

		local parsed_content = markview.parser.init(buffer);

		markview.renderer.clear(buffer);
		markview.renderer.render(buffer, parsed_content, markview.configuration)

		for _, window in ipairs(windows) do
			if markview.configuration.callbacks and markview.configuration.callbacks.on_enable then
				pcall(markview.configuration.callbacks.on_enable, buffer, window);
			end
			-- vim.wo[window].conceallevel = type(options.on_enable) == "table" and options.on_enable.conceallevel or 2;
			-- vim.wo[window].concealcursor = type(options.on_enable) == "table" and options.on_enable.concealcursor or "n";

			markview.keymaps.init(buffer, window, parsed_content, markview.configuration);
		end
	end
});

-- ISSUE: Work in progress
vim.api.nvim_create_autocmd({ "ModeChanged", "TextChanged" }, {
	buffer = vim.api.nvim_get_current_buf(),
	group = markview_augroup,

	callback = function (event)
		local buffer = event.buf;
		local windows = utils.find_attached_wins(event.buf);

		local mode = vim.api.nvim_get_mode().mode;

		if markview.state.enable == false then
			return;
		end

		if markview.state.buf_states[buffer] == false then
			return;
		end

		-- Only on mode change
		if event.event == "ModeChanged" then
			-- Call the on_mode_change callback before exiting
			if not markview.configuration.callbacks or not markview.configuration.callbacks.on_mode_change then
				return;
			end

			for _, window in ipairs(windows) do
				pcall(markview.configuration.callbacks.on_mode_change, buffer, window, mode);
			end
		end


		if vim.islist(markview.configuration.modes) and vim.list_contains(markview.configuration.modes, mode) then
			local parsed_content = markview.parser.init(buffer);
			local parse_start, parse_stop = utils.get_cursor_range(buffer, windows[1], markview.configuration);

			markview.renderer.clear(buffer);

			if vim.list_contains(markview.configuration.modes, "i") and mode == "i" then
				markview.renderer.render(buffer, parsed_content, markview.configuration, parse_start, parse_stop);
			else
				markview.renderer.render(buffer, parsed_content, markview.configuration);
			end

			local partial_contents = markview.parser.parse_range(event.buf, parse_start, parse_stop);
			local current_range = markview.renderer.get_content_range(partial_contents);

			markview.renderer.update_range(buffer, current_range);

			for _, window in ipairs(windows) do
				markview.keymaps.init(buffer, window, parsed_content, markview.configuration);
			end
		else
			markview.renderer.clear(buffer);
		end
	end
});

if not vim.list_contains(markview.configuration.modes, "i") then
	return;
end

local move_timer = vim.uv.new_timer();

vim.api.nvim_create_autocmd({ "CursorMovedI" }, {
	buffer = vim.api.nvim_get_current_buf(),
	group = markview_augroup,

	callback = function (event)
		if markview.state.enable == false then
			move_timer:stop();
			return;
		end

		if markview.state.buf_states[event.buf] == false then
			move_timer:stop();
			return;
		end

		move_timer:stop();
		move_timer:start(100, 0, vim.schedule_wrap(function ()
			local old_start, old_stop = _G.__markview_render_ranges[event.buf][1], _G.__markview_render_ranges[event.buf][2];
			local parse_start, parse_stop = utils.get_cursor_range(event.buf, 0, markview.configuration);

			vim.print(parse_start .. " : " .. parse_stop)
			local prev_contents = markview.parser.parse_range(event.buf, old_start, old_stop);
			local partial_contents = markview.parser.parse_range(event.buf, parse_start, parse_stop);

			local current_range = markview.renderer.get_content_range(partial_contents);

			-- Don't draw new things
			if _G.__markview_render_ranges[event.buf] and vim.deep_equal(_G.__markview_render_ranges[event.buf], current_range) then
				markview.renderer.clear_content_range(event.buf, partial_contents)
				return;
			end

			markview.renderer.clear_content_range(event.buf, partial_contents)

			markview.renderer.clear_content_range(event.buf, prev_contents);

			markview.renderer.render_in_range(event.buf, prev_contents, markview.configuration, draw_start, draw_stop);

			markview.renderer.update_range(event.buf, current_range);
		end));
	end
})

