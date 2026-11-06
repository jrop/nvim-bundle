rockspec_format = '3.0'
package = 'nvim-bundle'
version = '0.0.0-0'

source = {
  url = 'https://github.com/jrop/nvim-bundle',
}

dependencies = {
  'lua = 5.1',
}

test_dependencies = {
  'busted == 2.2.0-1',
  'luacov == 0.16.0-1',
}
