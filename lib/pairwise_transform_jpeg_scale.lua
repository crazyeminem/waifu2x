local pairwise_utils = require 'pairwise_transform_utils'
local iproc = require 'iproc'
local gm = require 'graphicsmagick'
local pairwise_transform = {}

local function add_jpeg_noise_(x, quality, options)
   for i = 1, #quality do
      x = gm.Image(x, "RGB", "DHW")
      x:format("jpeg"):depth(8)
      if torch.uniform() < options.jpeg_chroma_subsampling_rate then
	 -- YUV 420
	 x:samplingFactors({2.0, 1.0, 1.0})
      else
	 -- YUV 444
	 x:samplingFactors({1.0, 1.0, 1.0})
      end
      local blob, len = x:toBlob(quality[i])
      x:fromBlob(blob, len)
      x = x:toTensor("byte", "RGB", "DHW")
   end
   return x
end

local function add_jpeg_noise(src, style, level, options)
   if style == "art" then
      if level == 1 then
	 return add_jpeg_noise_(src, {torch.random(65, 85)}, options)
      elseif level == 2 or level == 3 then
	 -- level 2/3 adjusting by -nr_rate. for level3, -nr_rate=1
	 local r = torch.uniform()
	 if r > 0.4 then
	    return add_jpeg_noise_(src, {torch.random(27, 70)}, options)
	 elseif r > 0.1 then
	    local quality1 = torch.random(37, 70)
	    local quality2 = quality1 - torch.random(5, 10)
	    return add_jpeg_noise_(src, {quality1, quality2}, options)
	 else
	    local quality1 = torch.random(52, 70)
	    local quality2 = quality1 - torch.random(5, 15)
	    local quality3 = quality1 - torch.random(15, 25)
	    return add_jpeg_noise_(src, {quality1, quality2, quality3}, options)
	 end
      else
	 error("unknown noise level: " .. level)
      end
   elseif style == "photo" then
      -- level adjusting by -nr_rate
      return add_jpeg_noise_(src, {torch.random(30, 70)}, options)
   else
      error("unknown style: " .. style)
   end
end

function pairwise_transform.jpeg_scale(src, scale, style, noise_level, size, offset, n, options)
   local filters = options.downsampling_filters
   if options.data.filters then
      filters = options.data.filters
   end
   local unstable_region_offset = 8
   local downsampling_filter = filters[torch.random(1, #filters)]
   local blur = torch.uniform(options.resize_blur_min, options.resize_blur_max)
   local y = pairwise_utils.preprocess(src, size, options)
   assert(y:size(2) % 4 == 0 and y:size(3) % 4 == 0)
   local down_scale = 1.0 / scale
   local x
   if options.gamma_correction then
      local small = iproc.scale_with_gamma22(y, y:size(3) * down_scale,
					     y:size(2) * down_scale, downsampling_filter, blur)
      if options.x_upsampling then
	 x = iproc.scale(small, y:size(3), y:size(2), "Box")
      else
	 x = small
      end
   else
      local small = iproc.scale(y, y:size(3) * down_scale,
				  y:size(2) * down_scale, downsampling_filter, blur)
      if options.x_upsampling then
	 x = iproc.scale(small, y:size(3), y:size(2), "Box")
      else
	 x = small
      end
   end
   local scale_inner = scale
   if options.x_upsampling then
      scale_inner = 1
   end
   x = iproc.crop(x, unstable_region_offset, unstable_region_offset,
		  x:size(3) - unstable_region_offset, x:size(2) - unstable_region_offset)
   y = iproc.crop(y, unstable_region_offset * scale_inner, unstable_region_offset * scale_inner,
		  y:size(3) - unstable_region_offset * scale_inner, y:size(2) - unstable_region_offset * scale_inner)
   if options.x_upsampling then
      assert(x:size(2) % 4 == 0 and x:size(3) % 4 == 0)
      assert(x:size(1) == y:size(1) and x:size(2) == y:size(2) and x:size(3) == y:size(3))
   else
      assert(x:size(1) == y:size(1) and x:size(2) * scale == y:size(2) and x:size(3) * scale == y:size(3))
   end
   local batch = {}
   local lowres_y = gm.Image(y, "RGB", "DHW"):
      size(y:size(3) * 0.5, y:size(2) * 0.5, "Box"):
      size(y:size(3), y:size(2), "Box"):
      toTensor(t, "RGB", "DHW")
   local xs = {}
   local ns = {}
   local ys = {}
   local lowreses = {}
   for j = 1, 2 do
      -- TTA
      local xi, yi, ri
      if j == 1 then
	 xi = x
	 yi = y
	 ri = lowres_y
      else
	 xi = x:transpose(2, 3):contiguous()
	 yi = y:transpose(2, 3):contiguous()
	 ri = lowres_y:transpose(2, 3):contiguous()
      end
      local xv = image.vflip(xi)
      local yv = image.vflip(yi)
      local rv = image.vflip(ri)
      table.insert(xs, xi)
      table.insert(ys, yi)
      table.insert(lowreses, ri)
      table.insert(xs, xv)
      table.insert(ys, yv)
      table.insert(lowreses, rv)
      table.insert(xs, image.hflip(xi))
      table.insert(ys, image.hflip(yi))
      table.insert(lowreses, image.hflip(ri))
      table.insert(xs, image.hflip(xv))
      table.insert(ys, image.hflip(yv))
      table.insert(lowreses, image.hflip(rv))
   end
   for i = 1, n do
      local t = (i % #xs) + 1
      local xc, yc
      if torch.uniform() < options.nr_rate then
	 -- scale + noise reduction
	 if not ns[t] then
	    ns[t] = add_jpeg_noise(xs[t], style, noise_level, options)
	 end
	 xc, yc = pairwise_utils.active_cropping(ns[t], ys[t], lowreses[t],
						 size,
						 scale_inner,
						 options.active_cropping_rate,
						 options.active_cropping_tries)
      else
	 -- scale
	 xc, yc = pairwise_utils.active_cropping(xs[t], ys[t], lowreses[t],
						 size,
						 scale_inner,
						 options.active_cropping_rate,
						 options.active_cropping_tries)
      end
      xc = iproc.byte2float(xc)
      yc = iproc.byte2float(yc)
      if options.rgb then
      else
	 yc = image.rgb2yuv(yc)[1]:reshape(1, yc:size(2), yc:size(3))
	 xc = image.rgb2yuv(xc)[1]:reshape(1, xc:size(2), xc:size(3))
      end
      table.insert(batch, {xc, iproc.crop(yc, offset, offset, size - offset, size - offset)})
   end
   return batch
end
function pairwise_transform.test_jpeg_scale(src)
   torch.setdefaulttensortype("torch.FloatTensor")
   local options = {random_color_noise_rate = 0.5,
		    random_half_rate = 0.5,
		    random_overlay_rate = 0.5,
		    random_unsharp_mask_rate = 0.5,
		    active_cropping_rate = 0.5,
		    active_cropping_tries = 10,
		    max_size = 256,
		    x_upsampling = false,
		    downsampling_filters = "Box",
		    rgb = true
   }
   local image = require 'image'
   local src = image.lena()

   for i = 1, 10 do
      local xy = pairwise_transform.jpeg_scale(src, 2.0, "art", 1, 128, 7, 1, options)
      image.display({image = xy[1][1], legend = "y:" .. (i * 10), min = 0, max = 1})
      image.display({image = xy[1][2], legend = "x:" .. (i * 10), min = 0, max = 1})
   end
end
return pairwise_transform
