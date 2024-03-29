#!~/torch/install/bin/th

require 'torch'
require 'image'
require 'paths'
local commonFuncs = require '0_commonFuncs'



local sampleManifold = {}
function sampleManifold.sample(manifoldExp, sampleCategory, canvasHW, nSamples, data, model, outputDirPath, mean, var, nLatents, imgSize, numVPs, epoch, batchSize, targetBatchSize, testPhase, tanh, dropoutNet, VpToKeep, silhouetteInput, zEmbeddings, singleVPNet, conditional, expType, benchmark)
    local conditionalModel = conditional and 1 or 0
    if not expType or expType == 'randomSampling' then
        print ('==> Drawing ' .. (conditional and ' conditional random ' or 'random') .. ' samples. Configs: ' .. 'Num of Sample Sets: ' .. nSamples .. ', Canvas Size: ' .. canvasHW .. ' x ' .. canvasHW .. (zEmbeddings and ', Empirical Mean' or (', Mean: ' .. mean))  .. (zEmbeddings and ', Empirical Var' or (', Diag. Var: ' .. var)))
        expDirName = conditional and 'conditionalSamples' or 'randomSamples'
        if not zEmbeddings then
            paths.mkdir(string.format('%s/%s-Mean_%.2f-Var_%.2f/', outputDirPath, expDirName, mean, var))
        else
            paths.mkdir(string.format('%s/%s-empirical/', outputDirPath, expDirName))
        end
        local canvasSize = (not expType and conditional and canvasHW - 1) or canvasHW
        local meanVec = torch.Tensor(1, nLatents):fill(mean)
        local diagLogVarianceVec = torch.Tensor(1, nLatents):fill(var):log() -- Take the log of the diagonal elements of a covariance matrix
        local canvas = torch.Tensor(numVPs, canvasSize * imgSize, canvasSize * imgSize)
        local silhouetteCanvas = torch.Tensor(numVPs, canvasSize * imgSize, canvasSize * imgSize)
        for c=1, conditional and (data and #data.category) or 1 do
            local allowSampleForCategory = false
            if conditional and type(sampleCategory) == 'table' then
                for l=1, #sampleCategory do
                    if sampleCategory[l] == data.category[c] then
                        allowSampleForCategory = true
                    end
                end
            else
                allowSampleForCategory = true
            end
            if allowSampleForCategory or sampleCategory == '' or not expType then
                if conditional then
                    if not zEmbeddings then
                        savePathRandom = string.format('%s/%s-Mean_%.2f-Var_%.2f/%s/', outputDirPath, expDirName, mean, var, data.category[c])
                    else
                        savePathRandom = string.format('%s/%s-empirical/%s/', outputDirPath, expDirName, data.category[c])
                    end
                else
                    if not zEmbeddings then
                        savePathRandom = string.format('%s/%s-Mean_%.2f-Var_%.2f/', outputDirPath, expDirName, mean, var)
                    else
                        savePathRandom = string.format('%s/%s-empirical/', outputDirPath, expDirName)
                    end
                end
                for j=1, nSamples do
                    local counter = 1
                    local zVectors
                    if not zEmbeddings then
                        zVectors = commonFuncs.sampleDiagonalMVN(meanVec, diagLogVarianceVec, canvasSize ^ 2)
                    else
                        local tempZEmbeddings = {}
                        if conditional then
                            -- Use the empirical distribution for each category samples in the training set
                            local tempIndex = zEmbeddings[3]:eq(c):nonzero()
                            tempIndex = tempIndex:view(tempIndex:size(1))
                            tempZEmbeddings[1] = zEmbeddings[1]:index(1, tempIndex)
                            tempZEmbeddings[2] = zEmbeddings[2]:index(1, tempIndex)

                            -- tempZEmbeddings[1] = zEmbeddings[1]
                            -- tempZEmbeddings[2] = zEmbeddings[2]

                            tempZEmbeddings[2] = tempZEmbeddings[2]:exp():add(tempZEmbeddings[2].new():resizeAs(tempZEmbeddings[2]):rand(tempZEmbeddings[2]:size()):div(10)):log() -- Increase the variance for about 0.05 (~0.22 std)
                        else
                            tempZEmbeddings[1] = zEmbeddings[1]:clone()
                            tempZEmbeddings[2] = zEmbeddings[2]:clone():exp():add(zEmbeddings[2].new():resizeAs(zEmbeddings[2]):rand(zEmbeddings[2]:size()):div(10)):log() -- Increase the variance for about 0.05 (~0.22 std)
                        end
                        zVectors = commonFuncs.sampleDiagonalMVN({tempZEmbeddings[1]:mean(1):float(), tempZEmbeddings[1]:var(1):log():float()}, {tempZEmbeddings[2]:clone():exp():mean(1):log():float(), tempZEmbeddings[2]:clone():exp():var(1):log():float()}, canvasSize ^ 2)
                    end
                    for i=1, canvasSize ^ 2 do
                        local z
                        z = zVectors[{{i}}]
                        z = torch.cat(z, z, 1)
                        z = z:cuda()
                        local reconstruction, targetClassLabels
                        if conditional then
                            targetClassLabels = torch.zeros(2, #data.category)
                            for l=1, 2 do
                                targetClassLabels[l][c] = 1
                            end
                            targetClassLabels = targetClassLabels:type(model:type())
                            reconstruction = model:get(conditionalModel+4):forward({z, targetClassLabels})
                        else
                            reconstruction = model:get(4):forward(z)
                        end
                       
                        local silhouettes = reconstruction[2]:clone()
                        reconstruction[2] = nil
                        reconstruction = reconstruction[1]
                        collectgarbage()
                        if tanh then reconstruction = commonFuncs.normalizeBackToZeroToOne(reconstruction) end

                        for k=1, numVPs do
                            canvas[{{k}, {(counter-1) * imgSize + 1, counter * imgSize}, {(i - 1) % canvasSize * imgSize + 1, ((i - 1) % canvasSize + 1) * imgSize}}]:copy(reconstruction[{1, k}]:type(torch.getdefaulttensortype()))
                            silhouetteCanvas[{{k}, {(counter-1) * imgSize + 1, counter * imgSize}, {(i - 1) % canvasSize * imgSize + 1, ((i - 1) % canvasSize + 1) * imgSize}}]:copy(silhouettes[{1, k}]:type(torch.getdefaulttensortype()))
                        end
                        if i % canvasSize == 0 then counter = counter + 1 end
                        z = nil
                        reconstruction = nil
                        silhouettes = nil
                        collectgarbage()
                    end
                    paths.mkdir(string.format('%s/sample%d/', savePathRandom, j))
                    paths.mkdir(string.format('%s/sample%d/mask', savePathRandom, j))
                    for k=1, numVPs do
                        image.save(string.format(savePathRandom .. 'sample%d/VP-%d.png', j, k-1), canvas[{k}])
                        image.save(string.format(savePathRandom .. 'sample%d/mask/VP-%d.png', j, k-1), silhouetteCanvas[{k}])
                    end
                end
            end
        end -- END for k=1, conditional and #data.category or 1
        canvas = nil
        silhouetteCanvas = nil
        model:clearState()
        collectgarbage()
    end
    if not expType or expType and expType == 'interpolation' then
        expDirName = expType and 'interpolation' .. (commonFuncs.numOfDirs(outputDirPath)+1 >= 1 and  commonFuncs.numOfDirs(outputDirPath)+1 or 1) or 'interpolation' -- In case a directory has been created already, this will help putting the new results into a new directory
        paths.mkdir(string.format('%s/%s/', outputDirPath, expDirName))
        local savePathDataInterpolate = string.format('%s/%s', outputDirPath, expDirName)
        print ("==> Doing interpolation. Configs - Number of Samples: " .. nSamples - 2 .. ", Canvas Size: " .. canvasHW - 1 .. " X " .. canvasHW - 1)
        nSamples = nSamples - 1 --Just to save computation time
        canvasHW = canvasHW - 1 --Just to save computation time
        local classID = 0
        for class=1, #data.category do
            local continueFlag = false
            if #sampleCategory > 0 then
                for sampleNo=1, #sampleCategory do
                    if data.category[class] == sampleCategory[sampleNo] then
                        continueFlag = true
                    end
                end
            else
                continueFlag = true
            end

            if continueFlag then
                local numOfVPsToDrop = torch.zeros(1) -- A placeholder to hold the number of view points to be dropped for the current category
                local dropIndices = torch.zeros(numVPs) -- A placeholder to hold the indices of the tensor to be zeroed-out  -- Used for dropoutNet
                local pickedVPs = torch.Tensor(2) -- A placeholder to hold the view point to be kept -- Used for singleVPNet
                if not expType or VpToKeep >= numVPs then
                    pickedVPs[1] = torch.random(1, numVPs)
                    pickedVPs[2] = pickedVPs[1]
                else
                    pickedVPs[1] = VpToKeep
                    pickedVPs[2] = VpToKeep
                end

                local matchingElements = data.labels:eq(torch.Tensor(data.dataset:size(1)):fill(class)) -- Find the samples within one of the classes
                if matchingElements:sum() > 1 then
                    local tempData = data.dataset:index(1, torch.range(1, data.dataset:size(1))[matchingElements]:long()):clone() -- Extract the samples belonging to the class of interest
                    local batchIndices = torch.randperm(tempData:size(1)):long():split(math.max(math.ceil(batchSize/2), targetBatchSize))

                    -- Correct the last index set size
                    if #batchIndices > 1 then
                        local tempbatchIndices = {}
                        for ll=1, tempData:size(1) - math.max(math.ceil(batchSize/2), targetBatchSize) * (#batchIndices - 1) do
                            tempbatchIndices[ll] = batchIndices[#batchIndices][ll]
                        end
                        batchIndices[#batchIndices] = torch.LongTensor(tempbatchIndices)
                    end

                    local nTotalSamples = 0
                    local batchesVisited = 0
                    local i = 1
                    while nTotalSamples < nSamples and batchesVisited < #batchIndices do -- Do this for all samples
                        batchesVisited = batchesVisited + 1
                        local passFlag = true
                        if batchIndices[i]:size(1) + nTotalSamples > nSamples then
                            batchIndices[i] = batchIndices[i][{{1, nSamples - nTotalSamples}}]
                        end

                        if batchIndices[i]:size(1) == 1 then
                            batchIndices[i] = batchIndices[i]:repeatTensor(2)
                        end

                        if passFlag then
                            

                            local depthMaps, droppedInputs 
                            depthMaps = tempData:index(1, batchIndices[i]):clone():type(model:type())

                            -- Generate the mask for the current samples
                            local silhouettes = depthMaps:clone()
                            if tanh then
                                silhouettes[silhouettes:gt(-1)] = 1
                                silhouettes[silhouettes:eq(-1)] = 0
                            else
                                silhouettes[silhouettes:gt(0)] = 1
                            end

                            local predClassVec
                            droppedInputs = commonFuncs.dropInputVPs({depthMaps, silhouettes}, true, dropoutNet, numOfVPsToDrop, dropIndices, singleVPNet, pickedVPs)
                            if conditional then
                                mean, log_var, predictedClassScores = unpack(model:get(2):forward(silhouetteInput and droppedInputs[2] or droppedInputs[1]))
                                predClassVec = commonFuncs.computeClassificationAccuracy(predictedClassScores, nil, true, predictedClassScores:size(2))
                                model:get(conditionalModel+4):forward({model:get(3):forward({mean, log_var}), predClassVec})
                            else
                                model:forward(silhouetteInput and droppedInputs[2] or droppedInputs[1])
                            end
                            
                            local dataBeingUsed = depthMaps:clone()
                            local reconstructions = model:get(conditionalModel+4).output

                            local originalSilhouettesReconstructions = reconstructions[2]:clone():type(torch.getdefaulttensortype())
                            reconstructions[2] = nil
                            local originalReconstructions = reconstructions[1]:clone():type(torch.getdefaulttensortype())
                            collectgarbage()
                            if tanh then originalReconstructions = commonFuncs.normalizeBackToZeroToOne(originalReconstructions) dataBeingUsed = commonFuncs.normalizeBackToZeroToOne(dataBeingUsed) end

                            -- Create hot vectors for class-conditional interpolations
                            local targetClassHotVec
                            if conditional then
                                targetClassHotVec = torch.CudaTensor(2, #data.category):zero()
                                targetClassHotVec[{{}, {class}}] = 1
                            end

                            local zVecPrevExample
                            local canvas = torch.Tensor(numVPs, canvasHW * imgSize, canvasHW * imgSize)
                            local silhouetteCanvas = torch.Tensor(numVPs, canvasHW * imgSize, canvasHW * imgSize)
                            for l=1, nSamples > 2 and batchIndices[i]:size(1) or 2 do
                                nTotalSamples = nTotalSamples + 1

                                meanVec = model:get(2).output[1][{{l}}]:clone():type(torch.getdefaulttensortype())
                                diagLogVarianceVec = model:get(2).output[2][{{l}}]:clone():type(torch.getdefaulttensortype())
                                if var > 0 then
                                    diagLogVarianceVec:exp():mul(var):log()
                                end

                                -- Sample z vectors
                                local zVectors
                                zVectors = torch.zeros(canvasHW ^ 2, nLatents)
                                zVectors[2]:copy(model:get(3).output[l]:type(torch.getdefaulttensortype()))
                                zVectors[{{3, canvasHW ^ 2}}]:copy(commonFuncs.sampleDiagonalMVN(meanVec, diagLogVarianceVec, canvasHW ^ 2 - 2)) -- The minus 2 is there since for each depth map we have 1 original depth map and 1 reconstructed version of the same depth map. Therefore, we require 2 less sampled Z vectors

                                -- Prepare the vectors for doing interpolation
                                local interpolationCanvas = torch.Tensor(numVPs, canvasHW * imgSize, canvasHW * imgSize)
                                local interpolationsilhouetteCanvas
                                interpolationsilhouetteCanvas = torch.Tensor(numVPs, canvasHW * imgSize, canvasHW * imgSize)
                                local interpolationZVectors = torch.zeros(canvasHW ^ 2, nLatents)
                                if l >= 2 then
                                    if manifoldExp ~= 'data' then
                                        interpolationZVectors[{2}]:copy(zVecPrevExample)
                                        interpolationZVectors[{{3, canvasHW ^ 2 - 2}}]:copy(commonFuncs.interpolateZVectors(zVecPrevExample, zVectors[{{2}}], canvasHW ^ 2 - 4)) -- The minus 4 is there since for each depth map we have one original depth map, one reconstructed version of the same depth map before interpolation (both located on top left), one interpolation target reconstructed depth map along with its original depth map (located at the bottom right). Therefore, we require 4 less interpolated versions of Z vectors
                                        interpolationZVectors[{canvasHW ^ 2 - 1}]:copy(zVectors[{2}])
                                    end
                                
                                
                                    -- Fill up the canvas(es) by passing the z vectors through the decoder
                                    -- and drawing the result on the canvas for each view point
                                    local counter = 1
                                    for j=2, canvasHW ^ 2 do
                                        local samplesReconstructions, interpolationReconstructions, samplesSilhouettesReconstructions, interpolationSilhouettesReconstructions
                                        local zSamples = zVectors[{{j}}]:repeatTensor(2, 1)
                                        local zInterpolations = interpolationZVectors[{{j}}]:repeatTensor(2, 1)
                                        zSamples = zSamples:cuda() zInterpolations = zInterpolations:cuda()
                                        if manifoldExp ~= 'interpolate' then 
                                            samplesReconstructions = model:get(conditionalModel+4):forward(zSamples)
                                            samplesSilhouettesReconstructions = samplesReconstructions[2]:clone():type(torch.getdefaulttensortype())
                                            samplesReconstructions[2] = nil
                                            samplesReconstructions = samplesReconstructions[1]:clone():type(torch.getdefaulttensortype())
                                            collectgarbage()
                                        end
                                        if tanh then samplesReconstructions = commonFuncs.normalizeBackToZeroToOne(samplesReconstructions) end


                                        -- Fill the canvas(es)
                                        for k=1, numVPs do


                                            if manifoldExp ~= 'interpolate' then
                                                canvas[{{k}, {1, dataBeingUsed:size(3)}, {1, dataBeingUsed:size(3)}}] = dataBeingUsed[{{l}, {k}}]:type(torch.getdefaulttensortype())
                                                canvas[{{k}, {(counter-1) * imgSize + 1, counter * imgSize}, {(j - 1) % canvasHW * imgSize + 1, ((j - 1) % canvasHW + 1) * imgSize}}]:copy(samplesReconstructions[{1, k}]:type(torch.getdefaulttensortype()))
                                                silhouetteCanvas[{{k}, {1, silhouettes:size(3)}, {1, silhouettes:size(3)}}]:copy(silhouettes[{{l}, {k}}])
                                                silhouetteCanvas[{{k}, {(counter-1) * imgSize + 1, counter * imgSize}, {(j - 1) % canvasHW * imgSize + 1, ((j - 1) % canvasHW + 1) * imgSize}}]:copy(samplesSilhouettesReconstructions[{1, k}]:type(torch.getdefaulttensortype()))
                                            end

                                            if manifoldExp ~= 'data' then
                                                interpolationReconstructions = model:get(conditionalModel+4):forward(conditionalModel == 0 and zInterpolations or {zInterpolations, targetClassHotVec})
                                                interpolationSilhouettesReconstructions = interpolationReconstructions[2]:clone():type(torch.getdefaulttensortype())
                                                interpolationReconstructions[2] = nil
                                                interpolationReconstructions = interpolationReconstructions[1]:clone():type(torch.getdefaulttensortype())

                                                -- Fill the interpolation canvas
                                                interpolationsilhouetteCanvas[{{k}, {1, silhouettes:size(3)}, {1, silhouettes:size(3)}}]:copy(silhouettes[{{l - 1}, {k}}])
                                                interpolationsilhouetteCanvas[{{k}, {(counter-1) * imgSize + 1, counter * imgSize}, {(j - 1) % canvasHW * imgSize + 1, ((j - 1) % canvasHW + 1) * imgSize}}]:copy(interpolationSilhouettesReconstructions[{1, k}])
                                                if tanh then interpolationReconstructions = commonFuncs.normalizeBackToZeroToOne(interpolationReconstructions) end

                                                interpolationCanvas[{{k}, {1, dataBeingUsed:size(3)}, {1, dataBeingUsed:size(3)}}] = dataBeingUsed[{{l - 1}, {k}}]:type(torch.getdefaulttensortype())
                                                interpolationCanvas[{{k}, {(counter-1) * imgSize + 1, counter * imgSize}, {(j - 1) % canvasHW * imgSize + 1, ((j - 1) % canvasHW + 1) * imgSize}}]:copy(interpolationReconstructions[{1, k}]:type(torch.getdefaulttensortype()))
                                            end
                                        end
                                        if j % canvasHW == 0 then counter = counter + 1 end
                                        zSamples = nil
                                        zInterpolations = nil
                                        samplesReconstructions = nil
                                        samplesSilhouettesReconstructions = nil
                                        interpolationReconstructions = nil
                                        interpolationSilhouettesReconstructions = nil
                                        collectgarbage()
                                    end

                                    if manifoldExp ~= 'data' then
                                        for k=1, numVPs do
                                            interpolationCanvas[{{k}, {(counter-2) * imgSize + 1, (counter - 1) * imgSize}, {(canvasHW ^ 2 - 1) % canvasHW * imgSize + 1, ((canvasHW ^ 2 - 1) % canvasHW + 1) * imgSize}}] = dataBeingUsed[{{l}, {k}}]:type(torch.getdefaulttensortype())
                                            interpolationsilhouetteCanvas[{{k}, {(counter-2) * imgSize + 1, (counter - 1) * imgSize}, {(canvasHW ^ 2 - 1) % canvasHW * imgSize + 1, ((canvasHW ^ 2 - 1) % canvasHW + 1) * imgSize}}]:copy(silhouettes[{{l}, {k}}])
                                        end
                                    end

                                    if manifoldExp ~= 'interpolate' then
                                        paths.mkdir(string.format('%s/%s/example-%d/samples', savePathDataInterpolate, data.category[class], nTotalSamples - 1))
                                        paths.mkdir(string.format('%s/%s/example-%d/samples/mask', savePathDataInterpolate, data.category[class], nTotalSamples - 1))
                                    end
                                    if manifoldExp ~= 'data' then
                                        paths.mkdir(string.format('%s/%s/example-%d/', savePathDataInterpolate, data.category[class], nTotalSamples - 1))
                                        paths.mkdir(string.format('%s/%s/example-%d//mask', savePathDataInterpolate, data.category[class], nTotalSamples - 1))
                                    end
                                    for k=1, numVPs do
                                        
                                        if manifoldExp ~= 'interpolate' then
                                            image.save(string.format(savePathDataInterpolate .. '/%s/example-%d/samples/VP-%d.png', data.category[class], nTotalSamples - 1, k-1), canvas[{k}])
                                            image.save(string.format(savePathDataInterpolate .. '/%s/example-%d/samples/mask/VP-%d.png', data.category[class], nTotalSamples - 1, k-1), silhouetteCanvas[{k}])
                                        end
                                        if manifoldExp ~= 'data' then
                                            image.save(string.format(savePathDataInterpolate .. '/%s/example-%d/VP-%d.png', data.category[class], nTotalSamples - 1, k-1), interpolationCanvas[{k}])
                                            image.save(string.format(savePathDataInterpolate .. '/%s/example-%d/mask/VP-%d.png', data.category[class], nTotalSamples - 1, k-1), interpolationsilhouetteCanvas[{k}])
                                        end
                                    end
                                end
                                -- Clone the mean and [log] variance vectors for interpolation use
                                zVecPrevExample = zVectors[{{2}}]:clone()
                            end
                            canvas = nil
                            silhouetteCanvas = nil
                            silhouettes = nil
                            originalReconstructions = nil
                            originalSilhouettesReconstructions = nil
                            model:clearState()
                            collectgarbage()
                        end -- END if passFlag
                        i = i + 1
                    end -- END while loop
                    tempData = nil
                    model:clearState()
                    collectgarbage()
                end -- END if matchingElements:sum() > 1
            end -- END if continueFlag
        end -- END for class
    end -- END for if epoch % 3 == 0
end

return sampleManifold
