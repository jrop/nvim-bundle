-- The version this copy reports. The release task builds with
-- `--define "vim.g.nvim_bundle_version='<tag>'"`, so the published asset names
-- the release it came from. Nothing defines it in a checkout, so a checkout
-- reports the fallback.
--- @type string
local VERSION = vim.g.nvim_bundle_version or '0.1.0'

return VERSION
