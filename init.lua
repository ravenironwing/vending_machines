local modname = minetest.get_current_modname()

local open_forms = {} -- [playername] = { pos=..., detached_name=..., formname=... }

local function p2s(pos)
	return minetest.pos_to_string(pos)
end

local function pos_above(pos)
	return {x = pos.x, y = pos.y + 1, z = pos.z}
end

local function pos_below(pos)
	return {x = pos.x, y = pos.y - 1, z = pos.z}
end

local function same_pos(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function get_base_pos_from_any_part(pos)
	local node = minetest.get_node(pos)
	if node.name == modname .. ":vending_machine_off" or node.name == modname .. ":vending_machine_on" then
		return pos
	elseif node.name == modname .. ":vending_machine_top_off" or node.name == modname .. ":vending_machine_top_on" then
		local below = pos_below(pos)
		local bname = minetest.get_node(below).name
		if bname == modname .. ":vending_machine_off" or bname == modname .. ":vending_machine_on" then
			return below
		end
	end
	return nil
end

local function get_detached_name(playername, pos)
	return ("%s:pay_%s_%d"):format(modname, playername, minetest.hash_node_position(pos))
end

local function hopper_pull_from_vault(pos, hop_pos, hop_inv, hop_list)
	-- only allow hoppers directly below
	if not hop_pos or hop_pos.x ~= pos.x or hop_pos.y ~= pos.y - 1 or hop_pos.z ~= pos.z then
		return nil
	end

	local inv = minetest.get_inventory({type = "node", pos = pos})
	if not inv then
		return nil
	end

	local stack_id = mcl_util.select_stack(inv, "vault", hop_inv, hop_list, nil, 1)
	if stack_id ~= nil then
		return inv, "vault", stack_id
	end

	return nil
end

local function get_prices(meta)
	local t = minetest.deserialize(meta:get_string("prices"))
	if type(t) ~= "table" then
		t = {}
	end
	for i = 1, 9 do
		t[i] = math.max(1, math.floor(tonumber(t[i]) or 1))
	end
	return t
end

local function set_prices(meta, prices)
	meta:set_string("prices", minetest.serialize(prices))
end

local function get_affordable_take_count(requested_count, bundle_qty, bundle_price, payment_count)
	if bundle_qty < 1 or bundle_price < 1 or requested_count < 1 or payment_count < 1 then
		return 0
	end

	-- max whole bundles the player can afford
	local affordable_bundles = math.floor(payment_count / bundle_price)
	if affordable_bundles < 1 then
		return 0
	end

	-- max whole bundles contained in the requested take amount
	local requested_bundles = math.floor(requested_count / bundle_qty)
	if requested_bundles < 1 then
		return 0
	end

	local bundles = math.min(affordable_bundles, requested_bundles)
	return bundles * bundle_qty
end

local function get_quantities(meta)
	local t = minetest.deserialize(meta:get_string("quantities"))
	if type(t) ~= "table" then
		t = {}
	end
	for i = 1, 9 do
		t[i] = math.max(1, math.floor(tonumber(t[i]) or 1))
	end
	return t
end

local function set_quantities(meta, quantities)
	meta:set_string("quantities", minetest.serialize(quantities))
end

local function get_owner(meta)
	return meta:get_string("owner")
end

local function get_currency_stack(meta)
	local inv = meta:get_inventory()
	return inv:get_stack("currency", 1)
end

local function get_currency_name(meta)
	local stack = get_currency_stack(meta)
	if stack:is_empty() then
		return ""
	end
	return stack:get_name()
end

local function get_currency_desc(meta)
	local stack = get_currency_stack(meta)
	if stack:is_empty() then
		return "Not set"
	end
	return stack:get_short_description()
end

local function get_column(index)
	return ((index - 1) % 9) + 1
end

local function refund_and_close(playername)
	local ctx = open_forms[playername]
	if not ctx then
		return
	end

	local detached = minetest.get_inventory({type = "detached", name = ctx.detached_name})
	local player = minetest.get_player_by_name(playername)

	if detached and player then
		local pay = detached:get_stack("pay", 1)
		if not pay:is_empty() then
			local pinv = player:get_inventory()
			local leftover = pinv:add_item("main", pay)
			if not leftover:is_empty() then
				minetest.item_drop(leftover, player, player:get_pos())
			end
			detached:set_stack("pay", 1, "")
		end
	end

	minetest.remove_detached_inventory(ctx.detached_name)
	open_forms[playername] = nil
end

local function make_formspec(pos, playername)
	local meta = minetest.get_meta(pos)
	local owner = get_owner(meta)
	local prices = get_prices(meta)
	local quantities = get_quantities(meta)
	local is_owner = (playername == owner)
	local currency_desc = get_currency_desc(meta)
	local currency_name = get_currency_name(meta)
	local posstr = ("%d,%d,%d"):format(pos.x, pos.y, pos.z)

	local grid_x = 1.35
	local step_x = 1.25

	local fs = {}
	fs[#fs + 1] = "formspec_version[6]"
	fs[#fs + 1] = "size[14.8,14.9]"
	fs[#fs + 1] = "no_prepend[]"
	fs[#fs + 1] = "bgcolor[#1e1e1e;false]"
	fs[#fs + 1] = "listcolors[#555555;#777777;#222222]"

	fs[#fs + 1] = "label[0.3,0.2;Vending Machine]"
	fs[#fs + 1] = "label[3.8,0.2;Owner: " .. minetest.formspec_escape(owner ~= "" and owner or "Unknown") .. "]"

	-- top-right currency display
	if not is_owner then
		fs[#fs + 1] = "label[12.3,0.2;Currency: " .. minetest.formspec_escape(currency_desc) .. "]"
		fs[#fs + 1] = "box[12.6,0.69;1.12,1.12;#cfcfcf]"
		if currency_name ~= "" then
			fs[#fs + 1] = ("item_image[12.66,0.74;1,1;%s]"):format(minetest.formspec_escape(currency_name))
		end
	end

	-- left labels
	fs[#fs + 1] = "label[0.3,0.92;#items]"
	fs[#fs + 1] = "label[0.3,1.52;Cost]"

	-- first row: quantity
	for col = 1, 9 do
		local x = grid_x + (col - 1) * step_x
		if is_owner then
			fs[#fs + 1] = ("field[%f,0.68;1.0,0.6;qty_%d;;%s]"):format(
				x, col, minetest.formspec_escape(tostring(quantities[col]))
			)
			fs[#fs + 1] = ("field_close_on_enter[qty_%d;false]"):format(col)
		else
			fs[#fs + 1] = ("label[%f,0.98;%s]"):format(
				x + 0.35, minetest.formspec_escape(tostring(quantities[col]))
			)
		end
	end

	-- second row: cost
	for col = 1, 9 do
		local x = grid_x + (col - 1) * step_x
		if is_owner then
			fs[#fs + 1] = ("field[%f,1.28;1.0,0.6;price_%d;;%s]"):format(
				x, col, minetest.formspec_escape(tostring(prices[col]))
			)
			fs[#fs + 1] = ("field_close_on_enter[price_%d;false]"):format(col)
		else
			fs[#fs + 1] = ("label[%f,1.58;%s]"):format(
				x + 0.35, minetest.formspec_escape(tostring(prices[col]))
			)
		end
	end

	if is_owner then
		fs[#fs + 1] = "button[12.75,0.7;1.4,1.1;save_cfg;Save]"
	end

	fs[#fs + 1] = ("label[%f,2.15;Stock]"):format(grid_x)
	fs[#fs + 1] = ("list[nodemeta:%s;stock;%f,2.5;9,3;]"):format(posstr, grid_x)

	if is_owner then
		fs[#fs + 1] = ("label[%f,6.25;Currency]"):format(grid_x)
		fs[#fs + 1] = ("box[%f,6.42;1.12,1.12;#cfcfcf]"):format(grid_x - 0.06)
		fs[#fs + 1] = ("list[nodemeta:%s;currency;%f,6.48;1,1;]"):format(posstr, grid_x)

		fs[#fs + 1] = ("label[%f,6.25;Vault]"):format(grid_x + step_x)
		fs[#fs + 1] = ("list[nodemeta:%s;vault;%f,6.45;8,2;]"):format(posstr, grid_x + step_x)
	else
		local detached_name = get_detached_name(playername, pos)
		fs[#fs + 1] = ("label[%f,6.25;Payment]"):format(grid_x + 8 * step_x)
		fs[#fs + 1] = ("list[detached:%s;pay;%f,6.45;1,1;]"):format(
			minetest.formspec_escape(detached_name),
			grid_x + 8 * step_x
		)
	end

	fs[#fs + 1] = ("label[%f,9.15;Inventory]"):format(grid_x)
	fs[#fs + 1] = ("list[current_player;main;%f,9.55;9,4;]"):format(grid_x)

	fs[#fs + 1] = ("listring[nodemeta:%s;stock]"):format(posstr)
	fs[#fs + 1] = "listring[current_player;main]"

	return table.concat(fs, "")
end

local function show_formspec_for_player(player, pos)
	local playername = player:get_player_name()
	local meta = minetest.get_meta(pos)
	local currency_name = get_currency_name(meta)

	refund_and_close(playername)

	local detached_name = get_detached_name(playername, pos)
	local formname = ("%s:machine_%d"):format(modname, minetest.hash_node_position(pos))

	local detached = minetest.create_detached_inventory(detached_name, {
		allow_put = function(inv, listname, index, stack, putter)
			if listname ~= "pay" then
				return 0
			end
			if not putter or putter:get_player_name() ~= playername then
				return 0
			end
			if currency_name == "" then
				return 0
			end
			if stack:get_name() ~= currency_name then
				return 0
			end
			return stack:get_count()
		end,

		allow_take = function(inv, listname, index, stack, taker)
			if not taker or taker:get_player_name() ~= playername then
				return 0
			end
			return stack:get_count()
		end,

		allow_move = function()
			return 0
		end,
	}, playername)

	detached:set_size("pay", 1)

	open_forms[playername] = {
		pos = vector.new(pos),
		detached_name = detached_name,
		formname = formname,
	}

	minetest.show_formspec(playername, formname, make_formspec(pos, playername))
end

local function update_infotext(pos)
	local meta = minetest.get_meta(pos)
	local owner = get_owner(meta)
	meta:set_string("infotext", "Vending Machine (Owner: " .. owner .. ")")

	local top = pos_above(pos)
	local topname = minetest.get_node(top).name
	if topname == modname .. ":vending_machine_top_off" or topname == modname .. ":vending_machine_top_on" then
		local topmeta = minetest.get_meta(top)
		topmeta:set_string("infotext", "Vending Machine (Owner: " .. owner .. ")")
	end
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if not player then
		return false
	end

	local playername = player:get_player_name()
	local ctx = open_forms[playername]
	if not ctx or ctx.formname ~= formname then
		return false
	end

	local pos = ctx.pos

	local nname = minetest.get_node(pos).name
	if nname ~= modname .. ":vending_machine_off" and nname ~= modname .. ":vending_machine_on" then
		refund_and_close(playername)
		return true
	end

	local meta = minetest.get_meta(pos)
	local owner = get_owner(meta)

	if playername == owner and (fields.save_cfg or fields.quit or fields.key_enter_field) then
		local prices = get_prices(meta)
		local quantities = get_quantities(meta)
		local changed = false

		for i = 1, 9 do
			local qkey = "qty_" .. i
			if fields[qkey] ~= nil and fields[qkey] ~= "" then
				local v = tonumber(fields[qkey])
				if v and v >= 1 then
					v = math.floor(v)
					if quantities[i] ~= v then
						quantities[i] = v
						changed = true
					end
				end
			end

			local pkey = "price_" .. i
			if fields[pkey] ~= nil and fields[pkey] ~= "" then
				local v = tonumber(fields[pkey])
				if v and v >= 1 then
					v = math.floor(v)
					if prices[i] ~= v then
						prices[i] = v
						changed = true
					end
				end
			end
		end

		if changed then
			set_prices(meta, prices)
			set_quantities(meta, quantities)
		end
	end

	if fields.quit then
		refund_and_close(playername)
		return true
	end

	if fields.save_cfg then
		minetest.show_formspec(playername, formname, make_formspec(pos, playername))
		return true
	end

	return true
end)

minetest.register_on_leaveplayer(function(player)
	if player then
		refund_and_close(player:get_player_name())
	end
end)

minetest.register_node(modname .. ":vending_machine_off", {
	description = "Vending Machine",
	tiles = {
		"vending_machine_body.png",
		"vending_machine_body.png",
		"vending_machine_side.png",
		"vending_machine_side.png",
		"vending_machine_back_bottom.png",
		"vending_machine_front_bottom_off.png",
	},

	paramtype2 = "facedir",
	_mcl_hoppers_on_try_pull = hopper_pull_from_vault,
	is_ground_content = false,
	groups = {pickaxey = 1, handy = 1, container = 2},

	mesecons = {
		effector = {
			action_on = function(pos, node)
				local n = minetest.get_node(pos)
				n.name = modname .. ":vending_machine_on"
				minetest.swap_node(pos, n)

				local top = pos_above(pos)
				local t = minetest.get_node(top)
				if t.name == modname .. ":vending_machine_top_off" then
					t.name = modname .. ":vending_machine_top_on"
					minetest.swap_node(top, t)
				end
			end,
		}
	},

	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()

		inv:set_size("stock", 27)
		inv:set_size("currency", 1)
		inv:set_size("vault", 16)

		local prices = {}
		local quantities = {}
		for i = 1, 9 do
			prices[i] = 1
			quantities[i] = 1
		end
		set_prices(meta, prices)
		set_quantities(meta, quantities)
	end,

	after_place_node = function(pos, placer, itemstack, pointed_thing)
		if not placer then
			return
		end

		local top = pos_above(pos)
		local topnode = minetest.get_node(top)
		local topdef = minetest.registered_nodes[topnode.name]

		if topnode.name ~= "air" and not (topdef and topdef.buildable_to) then
			minetest.remove_node(pos)
			local pinv = placer:get_inventory()
			if pinv then
				pinv:add_item("main", ItemStack(modname .. ":vending_machine_off"))
			end
			minetest.chat_send_player(placer:get_player_name(), "Not enough room above for vending machine.")
			return
		end

		minetest.set_node(top, {
			name = modname .. ":vending_machine_top_off",
			param2 = minetest.get_node(pos).param2
		})

		local meta = minetest.get_meta(pos)
		meta:set_string("owner", placer:get_player_name())
		update_infotext(pos)
	end,

	on_rightclick = function(pos, node, clicker)
		if not clicker then
			return
		end
		show_formspec_for_player(clicker, pos)
	end,

	can_dig = function(pos, player)
		if not player then
			return false
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		return player:get_player_name() == owner
	end,

	after_destruct = function(pos, oldnode)
		local top = pos_above(pos)
		local tname = minetest.get_node(top).name
		if tname == modname .. ":vending_machine_top_off" or tname == modname .. ":vending_machine_top_on" then
			minetest.remove_node(top)
		end
	end,

	allow_metadata_inventory_put = function(pos, listname, index, stack, player)
		if not player then
			return 0
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		local playername = player:get_player_name()

		if listname == "stock" then
			if playername ~= owner then
				return 0
			end
			return stack:get_count()
		elseif listname == "currency" then
			if playername ~= owner then
				return 0
			end

			local inv = meta:get_inventory()
			local existing = inv:get_stack("currency", 1)
			if not existing:is_empty() then
				return 0
			end

			return 1
		elseif listname == "vault" then
			if playername ~= owner then
				return 0
			end
			return stack:get_count()
		end

		return 0
	end,

	allow_metadata_inventory_take = function(pos, listname, index, stack, player)
		if not player then
			return 0
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		local playername = player:get_player_name()

		if listname == "vault" or listname == "currency" then
			if playername ~= owner then
				return 0
			end
			return stack:get_count()
		end

		if listname == "stock" then
			if playername == owner then
				return stack:get_count()
			end

			-- OFF node: customers cannot buy
			return 0
		end

		return 0
	end,

	allow_metadata_inventory_move = function(pos, from_list, from_index, to_list, to_index, count, player)
		if not player then
			return 0
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)

		if player:get_player_name() ~= owner then
			return 0
		end

		if to_list == "currency" then
			return 0
		end

		if (from_list == "stock" and to_list == "stock") or
		   (from_list == "vault" and to_list == "vault") then
			return count
		end

		return 0
	end,

	on_metadata_inventory_take = function(pos, listname, index, stack, player)
		if not player or listname ~= "stock" then
			return
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		local playername = player:get_player_name()

		if playername == owner then
			return
		end

		-- OFF node: never charge customers because they should never be able to buy
	end,
})

minetest.register_node(modname .. ":vending_machine_on", {
	description = "Vending Machine",
	tiles = {
		"vending_machine_body.png",         -- top
		"vending_machine_body.png",         -- bottom
		"vending_machine_side.png",         -- right
		"vending_machine_side.png",         -- left
		"vending_machine_back_bottom.png",  -- back
		"vending_machine_front_bottom.png", -- front
	},

	paramtype2 = "facedir",
	_mcl_hoppers_on_try_pull = hopper_pull_from_vault,
	is_ground_content = false,
	light_source = 4,
	drop = modname .. ":vending_machine_off",
	groups = {pickaxey = 1, handy = 1, container = 2, not_in_creative_inventory = 1},

	mesecons = {
		effector = {
			action_off = function(pos, node)
				local n = minetest.get_node(pos)
				n.name = modname .. ":vending_machine_off"
				minetest.swap_node(pos, n)

				local top = pos_above(pos)
				local t = minetest.get_node(top)
				if t.name == modname .. ":vending_machine_top_on" then
					t.name = modname .. ":vending_machine_top_off"
					minetest.swap_node(top, t)
				end
			end,
		}
	},

	on_rightclick = function(pos, node, clicker)
		if not clicker then
			return
		end
		show_formspec_for_player(clicker, pos)
	end,

	can_dig = function(pos, player)
		if not player then
			return false
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		return player:get_player_name() == owner
	end,

	after_destruct = function(pos, oldnode)
		local top = pos_above(pos)
		local tname = minetest.get_node(top).name
		if tname == modname .. ":vending_machine_top_off" or tname == modname .. ":vending_machine_top_on" then
			minetest.remove_node(top)
		end
	end,

	allow_metadata_inventory_put = function(pos, listname, index, stack, player)
		if not player then
			return 0
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		local playername = player:get_player_name()

		if listname == "stock" then
			if playername ~= owner then
				return 0
			end
			return stack:get_count()
		elseif listname == "currency" then
			if playername ~= owner then
				return 0
			end

			local inv = meta:get_inventory()
			local existing = inv:get_stack("currency", 1)
			if not existing:is_empty() then
				return 0
			end

			return 1
		elseif listname == "vault" then
			if playername ~= owner then
				return 0
			end
			return stack:get_count()
		end

		return 0
	end,

	allow_metadata_inventory_take = function(pos, listname, index, stack, player)
		if not player then
			return 0
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		local playername = player:get_player_name()

		if listname == "vault" or listname == "currency" then
			if playername ~= owner then
				return 0
			end
			return stack:get_count()
		end

		if listname == "stock" then
			if playername == owner then
				return stack:get_count()
			end

			local currency_name = get_currency_name(meta)
			if currency_name == "" then
				return 0
			end

			local detached_name = get_detached_name(playername, pos)
			local payinv = minetest.get_inventory({type = "detached", name = detached_name})
			if not payinv then
				return 0
			end

			local pay = payinv:get_stack("pay", 1)
			if pay:is_empty() or pay:get_name() ~= currency_name then
				return 0
			end

			local prices = get_prices(meta)
			local quantities = get_quantities(meta)
			local col = get_column(index)

			local bundle_price = prices[col] or 1
			local bundle_qty = quantities[col] or 1
			local requested_count = stack:get_count()
			local payment_count = pay:get_count()

			local allowed_count = get_affordable_take_count(
				requested_count,
				bundle_qty,
				bundle_price,
				payment_count
			)

			return allowed_count
		end

		return 0
	end,

	allow_metadata_inventory_move = function(pos, from_list, from_index, to_list, to_index, count, player)
		if not player then
			return 0
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)

		if player:get_player_name() ~= owner then
			return 0
		end

		if to_list == "currency" then
			return 0
		end

		if (from_list == "stock" and to_list == "stock") or
		   (from_list == "vault" and to_list == "vault") then
			return count
		end

		return 0
	end,

	on_metadata_inventory_take = function(pos, listname, index, stack, player)
		if not player or listname ~= "stock" then
			return
		end

		local meta = minetest.get_meta(pos)
		local owner = get_owner(meta)
		local playername = player:get_player_name()

		if playername == owner then
			return
		end

		local detached_name = get_detached_name(playername, pos)
		local payinv = minetest.get_inventory({type = "detached", name = detached_name})
		if not payinv then
			return
		end

		local currency_name = get_currency_name(meta)
		if currency_name == "" then
			return
		end

		local pay = payinv:get_stack("pay", 1)
		if pay:is_empty() or pay:get_name() ~= currency_name then
			return
		end

		local prices = get_prices(meta)
		local quantities = get_quantities(meta)
		local col = get_column(index)

		local bundle_price = prices[col] or 1
		local bundle_qty = quantities[col] or 1
		local taken_count = stack:get_count()

		if taken_count % bundle_qty ~= 0 then
			return
		end

		local bundles = taken_count / bundle_qty
		local total_cost = bundle_price * bundles

		if pay:get_count() < total_cost then
			return
		end

		pay:set_count(pay:get_count() - total_cost)
		payinv:set_stack("pay", 1, pay)

		local inv = meta:get_inventory()
		local to_add = ItemStack(currency_name .. " " .. total_cost)
		local leftover = inv:add_item("vault", to_add)

		if not leftover:is_empty() then
			local p = payinv:get_stack("pay", 1)
			if p:is_empty() then
				payinv:set_stack("pay", 1, leftover)
			elseif p:get_name() == leftover:get_name() then
				p:set_count(p:get_count() + leftover:get_count())
				payinv:set_stack("pay", 1, p)
			else
				local buyer = minetest.get_player_by_name(playername)
				if buyer then
					local pinv = buyer:get_inventory()
					local rest = pinv:add_item("main", leftover)
					if not rest:is_empty() then
						minetest.item_drop(rest, buyer, buyer:get_pos())
					end
				end
			end
		end
	end,
})

minetest.register_node(modname .. ":vending_machine_top_off", {
	description = "Vending Machine Top",
	tiles = {
		"vending_machine_body.png",
		"vending_machine_body.png",
		"vending_machine_side.png",
		"vending_machine_side.png",
		"vending_machine_back_top.png",
		"vending_machine_front_top_off.png",
	},
	paramtype2 = "facedir",
	is_ground_content = false,
	drop = "",
	groups = {pickaxey = 1, handy = 1, not_in_creative_inventory = 1},
	on_rightclick = function(pos, node, clicker)
		if clicker then
			local base = pos_below(pos)
			if minetest.get_node(base).name == modname .. ":vending_machine_off"
			or minetest.get_node(base).name == modname .. ":vending_machine_on" then
				show_formspec_for_player(clicker, base)
			end
		end
	end,
	can_dig = function() return false end,
	after_destruct = function(pos, oldnode)
		local base = pos_below(pos)
		local bname = minetest.get_node(base).name
		if bname == modname .. ":vending_machine_off" or bname == modname .. ":vending_machine_on" then
			minetest.remove_node(base)
		end
	end,
})

minetest.register_node(modname .. ":vending_machine_top_on", {
	description = "Vending Machine Top",
	tiles = {
		"vending_machine_body.png",
		"vending_machine_body.png",
		"vending_machine_side.png",
		"vending_machine_side.png",
		"vending_machine_back_top.png",
		"vending_machine_front_top.png",
	},
	paramtype2 = "facedir",
	is_ground_content = false,
	light_source = 4,
	drop = "",
	groups = {pickaxey = 1, handy = 1, not_in_creative_inventory = 1},
	on_rightclick = function(pos, node, clicker)
		if clicker then
			local base = pos_below(pos)
			if minetest.get_node(base).name == modname .. ":vending_machine_off"
			or minetest.get_node(base).name == modname .. ":vending_machine_on" then
				show_formspec_for_player(clicker, base)
			end
		end
	end,
	can_dig = function() return false end,
	after_destruct = function(pos, oldnode)
		local base = pos_below(pos)
		local bname = minetest.get_node(base).name
		if bname == modname .. ":vending_machine_off" or bname == modname .. ":vending_machine_on" then
			minetest.remove_node(base)
		end
	end,
})

minetest.register_lbm({
	label = "Clean up orphaned vending machine halves",
	name = modname .. ":cleanup_orphaned_vending_parts",
	nodenames = {
		modname .. ":vending_machine_off",
		modname .. ":vending_machine_on",
		modname .. ":vending_machine_top_off",
		modname .. ":vending_machine_top_on",
	},
	run_at_every_load = true,
	action = function(pos, node)
		if node.name == modname .. ":vending_machine_off" or node.name == modname .. ":vending_machine_on" then
			local top = pos_above(pos)
			local topname = minetest.get_node(top).name
			if topname ~= modname .. ":vending_machine_top_off" and topname ~= modname .. ":vending_machine_top_on" then
				minetest.remove_node(pos)
			end
		elseif node.name == modname .. ":vending_machine_top_off" or node.name == modname .. ":vending_machine_top_on" then
			local base = pos_below(pos)
			local basename = minetest.get_node(base).name
			if basename ~= modname .. ":vending_machine_off" and basename ~= modname .. ":vending_machine_on" then
				minetest.remove_node(pos)
			end
		end
	end,
})

minetest.register_craft({
	output = modname .. ":vending_machine_off",
	recipe = {
		{"mcl_doors:iron_trapdoor", "xpanes:pane_natural_flat", "mcl_doors:iron_trapdoor"},
		{"mcl_doors:iron_door", "mcl_chests:chest", "mcl_doors:iron_door"},
		{"mcl_doors:iron_trapdoor", "mcl_comparators:comparator_off_comp", "mcl_doors:iron_trapdoor"},
	}
})

