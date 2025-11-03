--[[
	Copyright (c) 2025 @154090147
	Licensed under the BSD 3-Clause License. See LICENSE file for details.
--]]
--[[
	This is used for OSGL buffers (window.buffer, texture.buffer)
	Argue OSGL buffers only, which contain u32s (RGBA).
	
	NOTE: THIS IS STILL INCOMPLETE! IT DOES NOT ACTUALLY FOLLOW REAL STANDARDS!
]]

local module = {}

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Micro-optimizations
local random = math.random
local abs = math.abs
local clamp = math.clamp
local min = math.min
local max = math.max
local floor = math.floor
local ceil = math.ceil
local round = math.round
local sqrt = math.sqrt
local log = math.log
local exp = math.exp
local bufferCreate = buffer.create
local bufferReadu32 = buffer.readu32
local bufferWriteu32 = buffer.writeu32
local bufferFromString = buffer.fromstring
local bufferToString = buffer.tostring
local bufferLength = buffer.len
local bufferCopy = buffer.copy
local color3FromRGB = Color3.fromRGB

-- Constants
local pi = math.pi
local tau = math.pi * 2

-- Dependencies
local src = ReplicatedStorage:WaitForChild("src")
local OSGL = require(src.OSGL)
local OSGLColor = OSGL.color
local OSGLtypes = require(src.OSGL.types)

-- Variables
local downsampleTaps = {
	{dx = -2, dy = -2, w = 0.125},  -- A
	{dx =  0, dy = -2, w = 0.250},  -- B
	{dx =  2, dy = -2, w = 0.125},  -- C

	{dx = -1, dy = -1, w = 0.500},  -- D
	{dx =  1, dy = -1, w = 0.500},  -- E

	{dx = -2, dy =  0, w = 0.250},  -- F
	{dx =  0, dy =  0, w = 0.500},    -- G (center)
	{dx =  2, dy =  0, w = 0.250},  -- H

	{dx = -1, dy =  1, w = 0.500},  -- I
	{dx =  1, dy =  1, w = 0.500},  -- J

	{dx = -2, dy =  2, w = 0.125},  -- K
	{dx =  0, dy =  2, w = 0.250},  -- L
	{dx =  2, dy =  2, w = 0.125},  -- M
}
local tentKernel = {
	[-1] = {
		[-1] = 1,
		[0] = 2,
		[1] = 1
	},
	[0] = {
		[-1] = 2,
		[0] = 4,
		[1] = 2
	},
	[1] = {
		[-1] = 1,
		[0] = 2,
		[1] = 1
	}
}

-- OSGL functions
local function readPixel(bfr: buffer, bufferWidth: number, x: number, y: number): OSGLtypes.Color
	return bufferReadu32(bfr, (y * bufferWidth + x) * 4)
end
local function writePixel(bfr: buffer, bufferWidth: number, x: number, y: number, color: OSGLtypes.Color)
	bufferWriteu32(bfr, (y * bufferWidth + x) * 4, color)
end

-- Math utilities
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Kernels
local function G(x: number, y: number, sigma: number): number
	return (1/(tau*sigma^2))*exp(-((x^2 + y^2)/(2*sigma^2)))
end
local function generateGaussianKernel(radius: number, sigma: number): {}
	local kernel = {}
	local sum = 0
	-- Calculate the Gaussian weight for each position
	for offsetX = -radius, radius do
		kernel[offsetX] = {}
		for offsetY = -radius, radius do
			local distance = sqrt(offsetX^2 + offsetY^2)
			local weight = exp(-(distance^2) / (2 * sigma^2)) -- Gaussian function
			kernel[offsetX][offsetY] = weight
			sum += weight
		end
	end
	-- Normalize kernel
	for offsetX, row in kernel do
		for offsetY, weight in row do
			kernel[offsetX][offsetY] = weight / sum
		end
	end
	return kernel
end

-- Upsampling / Downsampling functions
local function resample(bfr: buffer, width: number, height: number, scale: number): (buffer, number, number)
	local newWidth = floor(width * scale)
	local newHeight = floor(height * scale)
	local newBuffer = bufferCreate(newWidth * newHeight * 4)
	for newY = 0, newHeight - 1 do
		for newX = 0, newWidth - 1 do
			local srcX = (newX + 0.5) / scale - 0.5
			local srcY = (newY + 0.5) / scale - 0.5
			srcX = clamp(srcX, 0, width - 1)
			srcY = clamp(srcY, 0, height - 1)
			local srcPixel = readPixel(bfr, width, floor(srcX), floor(srcY))
			writePixel(newBuffer, newWidth, newX, newY, srcPixel)
		end
	end
	return newBuffer, newWidth, newHeight
end

-- Inspired from unity's implementation / call of duty's next gen postprocessing presentation.
-- Samples pixels instead of 2x2 texels, so it's only an approximation.
local function downsample13Tap(bfr: buffer, width: number, height: number, factor: number): (buffer, number, number)
	--[[
		. . . . . . .
		. A . B . C .
		. . D . E . .
		. F . G . H .
		. . I . J . .
		. K . L . M .
		. . . . . . .
	--]]
	-- Calculate the new size of the texture
	local newWidth = width // factor --the int division is responsible for the slight shift to the right
	local newHeight = height // factor
	local newBuffer = bufferCreate(newWidth * newHeight * 4)
	for newY = 0, newHeight-1 do
		for newX = 0, newWidth-1 do
			-- Compute the corresponding source pixel positions
			local srcX, srcY = newX * factor, newY * factor
			local sumR, sumG, sumB = 0, 0, 0

			-- Sample each tap with clamped coordinates
			for _, tap in downsampleTaps do
				local sampleX = clamp(srcX + tap.dx, 0, width - 1)
				local sampleY = clamp(srcY + tap.dy, 0, height - 1)
				local pixel = readPixel(bfr, width, sampleX, sampleY)
				
				local r, g, b = OSGLColor.read(pixel)
				sumR += r * tap.w
				sumG += g * tap.w
				sumB += b * tap.w
			end

			local finalR = clamp(sumR // 4.0 + 0.5, 0, 255) -- 4.0 because that's the total weights
			local finalB = clamp(sumB // 4.0 + 0.5, 0, 255) -- 0.5 because of the flooring
			local finalG = clamp(sumG // 4.0 + 0.5, 0, 255)

			local newPixel = OSGLColor.newRGB(finalR, finalG, finalB)
			writePixel(newBuffer, newWidth, newX, newY, newPixel)
		end
	end
	return newBuffer, newWidth, newHeight
end

-- Mipmapping and Merging
local function mergeMips(mipA: buffer, widthA: number, heightA: number, mipB: buffer, widthB: number, heightB: number)
	local scaleFactor = min(widthA // widthB, heightA // heightB)
	local upscaledMip, upscaledWidth, upscaledHeight = resample(mipB, widthB, heightB, scaleFactor)
	local mergedBuffer = bufferCreate(widthA * heightA * 4)
	for y = 0, heightA - 1 do
		for x = 0, widthA - 1 do
			local colorA = readPixel(mipA, widthA, x, y)
			local colorB = readPixel(upscaledMip, upscaledWidth, clamp(x, 0, upscaledWidth-1), clamp(y, 0, upscaledHeight-1)) --clamp incase of percision errors when mipB was downsampled
			local blendedColor = OSGLColor.newRGB(
				(OSGLColor.r(colorA) + OSGLColor.r(colorB)) / 2,
				(OSGLColor.g(colorA) + OSGLColor.g(colorB)) / 2,
				(OSGLColor.b(colorA) + OSGLColor.b(colorB)) / 2
			)
			writePixel(mergedBuffer, widthA, x, y, blendedColor)
		end
	end
	return mergedBuffer
end
local function mergeTextures(bufferA: buffer, bufferB: buffer, width: number, height: number, blendMethod: string, weight: number): buffer
	local finalBuffer = bufferCreate(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local colorA = readPixel(bufferA, width, x, y)
			local colorB = readPixel(bufferB, width, x, y)
			local finalColor
			if blendMethod == "add" then
				finalColor = OSGLColor.new(
					clamp(OSGLColor.r(colorA) + OSGLColor.r(colorB) * weight, 0, 255),
					clamp(OSGLColor.g(colorA) + OSGLColor.g(colorB) * weight, 0, 255),
					clamp(OSGLColor.b(colorA) + OSGLColor.b(colorB) * weight, 0, 255),
					clamp(OSGLColor.a(colorA) + OSGLColor.a(colorB) * weight, 0, 255)
				)
			else
				finalColor = OSGLColor.BLACK
			end
			writePixel(finalBuffer, width, x, y, finalColor)
		end
	end
	return finalBuffer
end

-- Post-processing functions
local function postprocess(bfr: buffer, width: number, height: number, radius: number, callback: func, ...): buffer
	-- Sanitization
	radius = max(radius, 1)
	-- Compute
	local newBuffer = bufferCreate(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local neighboringPixels = {}

			for offsetX = -radius, radius do
				neighboringPixels[offsetX] = {}
				for offsetY = -radius, radius do
					if x + offsetX >= 0 and x + offsetX < width and y + offsetY >= 0 and y + offsetY < height then
						neighboringPixels[offsetX][offsetY] = readPixel(bfr, width, x + offsetX, y + offsetY)
					end
				end
				if next(neighboringPixels[offsetX]) == nil then
					neighboringPixels[offsetX] = nil
				end
			end

			local newColor = callback(neighboringPixels, ...)
			writePixel(newBuffer, width, x, y, newColor)
		end
	end
	return newBuffer
end
local function thresholdPixel(neighboringPixels: table, threshold: number): OSGLtypes.Color
	local pixel = neighboringPixels[0][0]
	local r, g, b = OSGLColor.read(pixel)
	local luminance = 0.299 * r + 0.587 * g + 0.114 * b
	return (luminance > threshold) and pixel or OSGLColor.BLACK --TODO: instead of returning black, return a weighted/dummed down version of the pixel for smoother bloom
end
local function boxBlur(neighboringPixels: {}): OSGLtypes.Color
	local meanR, meanG, meanB = 0, 0, 0
	local donePixels = 0

	for _, x: {} in neighboringPixels do
		for _, y: OSGLtypes.Color in x do
			meanR += OSGLColor.r(y)
			meanG += OSGLColor.g(y)
			meanB += OSGLColor.b(y)
			donePixels += 1
		end
	end

	meanR /= donePixels
	meanG /= donePixels
	meanB /= donePixels

	return OSGLColor.newRGB(meanR, meanG, meanB)
end
local function weightedBlur(neighboringPixels: {}, kernel: {}): OSGLtypes.Color
	local weightedR, weightedG, weightedB = 0, 0, 0
	local totalWeight = 0

	for offsetX, x: {} in neighboringPixels do
		for offsetY, y: OSGLtypes.Color in x do
			local weight = kernel[offsetX] and kernel[offsetX][offsetY] or 0
			weightedR += OSGLColor.r(y) * weight
			weightedG += OSGLColor.g(y) * weight
			weightedB += OSGLColor.b(y) * weight
			totalWeight += weight
		end
	end

	-- Normalize the weighted values to ensure colors are averaged properly
	weightedR /= totalWeight
	weightedG /= totalWeight
	weightedB /= totalWeight

	return OSGLColor.newRGB(weightedR, weightedG, weightedB)
end
local function nlm(neighboringPixels: {}, lambda: number, k: number): OSGLtypes.Color
	local sumR, sumG, sumB = 0, 0, 0
	local weightSum = 0

	local centerR, centerG, centerB = OSGLColor.read(neighboringPixels[0][0])
	centerR, centerG, centerB = centerR / 255, centerG / 255, centerB / 255
	for _, x: {} in neighboringPixels do
		for _, y: OSGLtypes.Color in x do
			local r, g, b = OSGLColor.read(y)
			r, g, b = r / 255, g / 255, b / 255

			local diff = sqrt((r - centerR)^2 + (g - centerG)^2 + (b - centerB)^2)
			local weight = exp(-(diff^2 / k^2))

			sumR += r * weight
			sumG += g * weight
			sumB += b * weight
			weightSum += weight
		end
	end
	if weightSum == 0 then
		weightSum = 1
	end

	-- Compute final color value blended between the center and diffused neighbors.
	local computedR = centerR * (1 - lambda) + (sumR / weightSum) * lambda
	local computedG = centerG * (1 - lambda) + (sumG / weightSum) * lambda
	local computedB = centerB * (1 - lambda) + (sumB / weightSum) * lambda

	return OSGLColor.newRGB(
		clamp(computedR * 255, 0, 255),
		clamp(computedG * 255, 0, 255),
		clamp(computedB * 255, 0, 255)
	)
end

-- API
function module.nlm(bfr: buffer, width: number, radius: number, lambda: number, k: number): buffer
	local bytes = bufferLength(bfr)
	local height: number = bytes / (width * 4)
	bfr = postprocess(bfr, width, height, radius, nlm, lambda, k)
	return bfr
end
function module.gaussianBlur(bfr: buffer, width: number, radius: number, sigma: number): buffer
	local bytes = bufferLength(bfr)
	local height: number = bytes / (width * 4)
	bfr = postprocess(bfr, width, height, radius, weightedBlur, generateGaussianKernel(radius, sigma))
	return bfr
end
function module.boxBlur(bfr: buffer, width: number, radius: number): buffer
	local bytes = bufferLength(bfr)
	local height: number = bytes / (width * 4)
	bfr = postprocess(bfr, width, height, radius, boxBlur)
	return bfr
end

function module.naivebloom(bfr: buffer, width: number, threshold: number, intensity: number, radius)
	-- Constants
	local totalBytes = bufferLength(bfr)
	local height: number = totalBytes / (width * 4)
	
	-- Generate kernel
	local kernel = generateGaussianKernel(radius, 3.5)
	
	-- Generate the bloom buffer
	local bloom = postprocess(bfr, width, height, 0, thresholdPixel, threshold)
	bloom = postprocess(bloom, width, height, radius, weightedBlur, kernel)
	bloom = mergeTextures(bfr, bloom, width, height, "add", intensity)
	
	return bloom
end

return module
