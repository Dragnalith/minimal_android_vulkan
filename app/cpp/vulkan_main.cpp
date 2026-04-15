#include <android_native_app_glue.h>
#include <android/asset_manager.h>
#include <android/log.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_android.h>

#include <cmath>
#include <ctime>
#include <stdexcept>
#include <string>
#include <vector>

#define LOG_TAG "VulkanTriangle"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static std::vector<char> loadAsset(AAssetManager* mgr, const char* name) {
    AAsset* asset = AAssetManager_open(mgr, name, AASSET_MODE_BUFFER);
    if (!asset)
        throw std::runtime_error(std::string("Cannot open asset: ") + name);
    size_t size = AAsset_getLength(asset);
    std::vector<char> buf(size);
    AAsset_read(asset, buf.data(), size);
    AAsset_close(asset);
    return buf;
}

static VkShaderModule createShaderModule(VkDevice dev,
                                         const std::vector<char>& code) {
    VkShaderModuleCreateInfo ci{};
    ci.sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = code.size();
    ci.pCode    = reinterpret_cast<const uint32_t*>(code.data());
    VkShaderModule mod = VK_NULL_HANDLE;
    if (vkCreateShaderModule(dev, &ci, nullptr, &mod) != VK_SUCCESS)
        throw std::runtime_error("vkCreateShaderModule failed");
    return mod;
}

static uint32_t findQueueFamily(VkPhysicalDevice physDev, VkSurfaceKHR surface) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physDev, &count, nullptr);
    std::vector<VkQueueFamilyProperties> props(count);
    vkGetPhysicalDeviceQueueFamilyProperties(physDev, &count, props.data());

    for (uint32_t i = 0; i < count; ++i) {
        VkBool32 presentSupport = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(physDev, i, surface, &presentSupport);
        if ((props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && presentSupport)
            return i;
    }
    throw std::runtime_error("No suitable queue family found");
}

struct PushConstants {
    float offsetX;
    float offsetY;
    float scale;
};

struct VulkanState {
    VkInstance               instance    = VK_NULL_HANDLE;
    VkSurfaceKHR             surface     = VK_NULL_HANDLE;
    VkPhysicalDevice         physDev     = VK_NULL_HANDLE;
    VkDevice                 device      = VK_NULL_HANDLE;
    VkQueue                  queue       = VK_NULL_HANDLE;
    VkSwapchainKHR           swapchain   = VK_NULL_HANDLE;
    VkFormat                 swapFormat  = VK_FORMAT_UNDEFINED;
    VkRenderPass             renderPass  = VK_NULL_HANDLE;
    VkPipelineLayout         pipeLayout  = VK_NULL_HANDLE;
    VkPipeline               pipeline    = VK_NULL_HANDLE;
    std::vector<VkImage>     swapImages;
    std::vector<VkImageView> swapViews;
    std::vector<VkFramebuffer> framebuffers;
    VkCommandPool            cmdPool     = VK_NULL_HANDLE;
    std::vector<VkCommandBuffer> cmdBufs;
    VkSemaphore              imgAvail   = VK_NULL_HANDLE;
    VkSemaphore              renderDone = VK_NULL_HANDLE;
    VkFence                  frameFence = VK_NULL_HANDLE;
    VkExtent2D               extent     = {};
    uint32_t                 queueFamily = 0;
    bool                     initialized = false;

    float posX = 0.0f, posY = 0.0f;
    float velX = 0.6f, velY = 0.8f;
    struct timespec lastTime{};
};

static VulkanState gState;

static void initVulkan(android_app* app) {
    AAssetManager* mgr = app->activity->assetManager;

    const char* instExts[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_KHR_ANDROID_SURFACE_EXTENSION_NAME,
    };
    VkApplicationInfo appInfo{};
    appInfo.sType           = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "VulkanTriangle";
    appInfo.apiVersion      = VK_API_VERSION_1_0;

    VkInstanceCreateInfo ici{};
    ici.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo        = &appInfo;
    ici.enabledExtensionCount   = 2;
    ici.ppEnabledExtensionNames = instExts;
    if (vkCreateInstance(&ici, nullptr, &gState.instance) != VK_SUCCESS)
        throw std::runtime_error("vkCreateInstance failed");

    VkAndroidSurfaceCreateInfoKHR sci{};
    sci.sType  = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
    sci.window = app->window;
    auto createSurface = reinterpret_cast<PFN_vkCreateAndroidSurfaceKHR>(
        vkGetInstanceProcAddr(gState.instance, "vkCreateAndroidSurfaceKHR"));
    if (!createSurface ||
        createSurface(gState.instance, &sci, nullptr, &gState.surface) != VK_SUCCESS)
        throw std::runtime_error("vkCreateAndroidSurfaceKHR failed");

    uint32_t devCount = 0;
    vkEnumeratePhysicalDevices(gState.instance, &devCount, nullptr);
    if (devCount == 0) throw std::runtime_error("No Vulkan physical device found");
    std::vector<VkPhysicalDevice> devs(devCount);
    vkEnumeratePhysicalDevices(gState.instance, &devCount, devs.data());
    gState.physDev = devs[0];

    gState.queueFamily = findQueueFamily(gState.physDev, gState.surface);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci{};
    qci.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = gState.queueFamily;
    qci.queueCount       = 1;
    qci.pQueuePriorities = &prio;

    const char* devExts[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo dci{};
    dci.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount    = 1;
    dci.pQueueCreateInfos       = &qci;
    dci.enabledExtensionCount   = 1;
    dci.ppEnabledExtensionNames = devExts;
    if (vkCreateDevice(gState.physDev, &dci, nullptr, &gState.device) != VK_SUCCESS)
        throw std::runtime_error("vkCreateDevice failed");
    vkGetDeviceQueue(gState.device, gState.queueFamily, 0, &gState.queue);

    VkSurfaceCapabilitiesKHR caps{};
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gState.physDev, gState.surface, &caps);
    gState.extent = caps.currentExtent;

    uint32_t fmtCount = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(gState.physDev, gState.surface, &fmtCount, nullptr);
    std::vector<VkSurfaceFormatKHR> formats(fmtCount);
    vkGetPhysicalDeviceSurfaceFormatsKHR(gState.physDev, gState.surface, &fmtCount, formats.data());
    gState.swapFormat = formats[0].format;

    uint32_t imgCount = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && imgCount > caps.maxImageCount)
        imgCount = caps.maxImageCount;

    VkSwapchainCreateInfoKHR swci{};
    swci.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    swci.surface          = gState.surface;
    swci.minImageCount    = imgCount;
    swci.imageFormat      = gState.swapFormat;
    swci.imageColorSpace  = formats[0].colorSpace;
    swci.imageExtent      = gState.extent;
    swci.imageArrayLayers = 1;
    swci.imageUsage       = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swci.preTransform     = caps.currentTransform;
    VkCompositeAlphaFlagBitsKHR compositeAlpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    for (auto flag : {VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
                      VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
                      VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
                      VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR}) {
        if (caps.supportedCompositeAlpha & flag) { compositeAlpha = flag; break; }
    }
    swci.compositeAlpha   = compositeAlpha;
    swci.presentMode      = VK_PRESENT_MODE_FIFO_KHR;
    swci.clipped          = VK_TRUE;
    if (vkCreateSwapchainKHR(gState.device, &swci, nullptr, &gState.swapchain) != VK_SUCCESS)
        throw std::runtime_error("vkCreateSwapchainKHR failed");

    vkGetSwapchainImagesKHR(gState.device, gState.swapchain, &imgCount, nullptr);
    gState.swapImages.resize(imgCount);
    vkGetSwapchainImagesKHR(gState.device, gState.swapchain, &imgCount,
                            gState.swapImages.data());
    gState.swapViews.resize(imgCount);
    for (uint32_t i = 0; i < imgCount; ++i) {
        VkImageViewCreateInfo vci{};
        vci.sType            = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vci.image            = gState.swapImages[i];
        vci.viewType         = VK_IMAGE_VIEW_TYPE_2D;
        vci.format           = gState.swapFormat;
        vci.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        vkCreateImageView(gState.device, &vci, nullptr, &gState.swapViews[i]);
    }

    VkAttachmentDescription att{};
    att.format        = gState.swapFormat;
    att.samples       = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp        = VK_ATTACHMENT_LOAD_OP_CLEAR;
    att.storeOp       = VK_ATTACHMENT_STORE_OP_STORE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    att.finalLayout   = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference ref{ 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub{};
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments    = &ref;

    VkRenderPassCreateInfo rpci{};
    rpci.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpci.attachmentCount = 1;
    rpci.pAttachments    = &att;
    rpci.subpassCount    = 1;
    rpci.pSubpasses      = &sub;
    vkCreateRenderPass(gState.device, &rpci, nullptr, &gState.renderPass);

    auto vertCode = loadAsset(mgr, "triangle.vert.spv");
    auto fragCode = loadAsset(mgr, "triangle.frag.spv");
    VkShaderModule vertMod = createShaderModule(gState.device, vertCode);
    VkShaderModule fragMod = createShaderModule(gState.device, fragCode);

    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage  = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertMod;
    stages[0].pName  = "main";
    stages[1].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragMod;
    stages[1].pName  = "main";

    VkPipelineVertexInputStateCreateInfo   vi{};
    vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    VkPipelineInputAssemblyStateCreateInfo ia{};
    ia.sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkViewport vp{ 0, 0, (float)gState.extent.width, (float)gState.extent.height,
                   0.0f, 1.0f };
    VkRect2D sc{ {0, 0}, gState.extent };
    VkPipelineViewportStateCreateInfo vs{};
    vs.sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vs.viewportCount = 1; vs.pViewports = &vp;
    vs.scissorCount  = 1; vs.pScissors  = &sc;

    VkPipelineRasterizationStateCreateInfo rs{};
    rs.sType       = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode    = VK_CULL_MODE_BACK_BIT;
    rs.frontFace   = VK_FRONT_FACE_CLOCKWISE;
    rs.lineWidth   = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms{};
    ms.sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineColorBlendAttachmentState cba{};
    cba.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                         VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo cb{};
    cb.sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1;
    cb.pAttachments    = &cba;

    VkPushConstantRange pcRange{};
    pcRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcRange.offset     = 0;
    pcRange.size       = sizeof(PushConstants);

    VkPipelineLayoutCreateInfo plci{};
    plci.sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plci.pushConstantRangeCount = 1;
    plci.pPushConstantRanges    = &pcRange;
    vkCreatePipelineLayout(gState.device, &plci, nullptr, &gState.pipeLayout);

    VkGraphicsPipelineCreateInfo gpci{};
    gpci.sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gpci.stageCount          = 2;
    gpci.pStages             = stages;
    gpci.pVertexInputState   = &vi;
    gpci.pInputAssemblyState = &ia;
    gpci.pViewportState      = &vs;
    gpci.pRasterizationState = &rs;
    gpci.pMultisampleState   = &ms;
    gpci.pColorBlendState    = &cb;
    gpci.layout              = gState.pipeLayout;
    gpci.renderPass          = gState.renderPass;
    vkCreateGraphicsPipelines(gState.device, VK_NULL_HANDLE, 1, &gpci, nullptr,
                              &gState.pipeline);

    vkDestroyShaderModule(gState.device, vertMod, nullptr);
    vkDestroyShaderModule(gState.device, fragMod, nullptr);

    gState.framebuffers.resize(imgCount);
    for (uint32_t i = 0; i < imgCount; ++i) {
        VkFramebufferCreateInfo fci{};
        fci.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fci.renderPass      = gState.renderPass;
        fci.attachmentCount = 1;
        fci.pAttachments    = &gState.swapViews[i];
        fci.width           = gState.extent.width;
        fci.height          = gState.extent.height;
        fci.layers          = 1;
        vkCreateFramebuffer(gState.device, &fci, nullptr, &gState.framebuffers[i]);
    }

    VkCommandPoolCreateInfo cpci{};
    cpci.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpci.queueFamilyIndex = gState.queueFamily;
    cpci.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    vkCreateCommandPool(gState.device, &cpci, nullptr, &gState.cmdPool);

    gState.cmdBufs.resize(imgCount);
    VkCommandBufferAllocateInfo cbai{};
    cbai.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool        = gState.cmdPool;
    cbai.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = imgCount;
    vkAllocateCommandBuffers(gState.device, &cbai, gState.cmdBufs.data());

    VkSemaphoreCreateInfo semi{};
    semi.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    vkCreateSemaphore(gState.device, &semi, nullptr, &gState.imgAvail);
    vkCreateSemaphore(gState.device, &semi, nullptr, &gState.renderDone);

    VkFenceCreateInfo fci2{};
    fci2.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fci2.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    vkCreateFence(gState.device, &fci2, nullptr, &gState.frameFence);

    clock_gettime(CLOCK_MONOTONIC, &gState.lastTime);
    gState.initialized = true;
    LOGI("Vulkan initialized successfully");
}

static void drawFrame() {
    if (!gState.initialized) return;

    constexpr float SCALE    = 0.5f;
    constexpr float HALF_TRI = 0.5f * SCALE;

    struct timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    float dt = (float)(now.tv_sec  - gState.lastTime.tv_sec)
             + (float)(now.tv_nsec - gState.lastTime.tv_nsec) * 1e-9f;
    gState.lastTime = now;
    if (dt > 0.1f) dt = 0.1f;

    float aspect = (float)gState.extent.width / (float)gState.extent.height;
    float boundX = 1.0f - HALF_TRI / aspect;
    float boundY = 1.0f - HALF_TRI;

    gState.posX += gState.velX * dt;
    gState.posY += gState.velY * dt;

    if (gState.posX >  boundX) { gState.posX =  boundX; gState.velX = -gState.velX; }
    if (gState.posX < -boundX) { gState.posX = -boundX; gState.velX = -gState.velX; }
    if (gState.posY >  boundY) { gState.posY =  boundY; gState.velY = -gState.velY; }
    if (gState.posY < -boundY) { gState.posY = -boundY; gState.velY = -gState.velY; }

    vkWaitForFences(gState.device, 1, &gState.frameFence, VK_TRUE, UINT64_MAX);
    vkResetFences(gState.device, 1, &gState.frameFence);

    uint32_t imgIdx = 0;
    vkAcquireNextImageKHR(gState.device, gState.swapchain, UINT64_MAX,
                          gState.imgAvail, VK_NULL_HANDLE, &imgIdx);

    VkCommandBuffer cmd = gState.cmdBufs[imgIdx];
    vkResetCommandBuffer(cmd, 0);

    VkCommandBufferBeginInfo bi{};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);

    VkClearValue clear{};
    clear.color = {{0.0f, 0.0f, 0.0f, 1.0f}};

    VkRenderPassBeginInfo rpbi{};
    rpbi.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpbi.renderPass      = gState.renderPass;
    rpbi.framebuffer     = gState.framebuffers[imgIdx];
    rpbi.renderArea      = { {0, 0}, gState.extent };
    rpbi.clearValueCount = 1;
    rpbi.pClearValues    = &clear;

    vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, gState.pipeline);

    PushConstants pc{ gState.posX, gState.posY, SCALE };
    vkCmdPushConstants(cmd, gState.pipeLayout, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(pc), &pc);

    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);
    vkEndCommandBuffer(cmd);

    VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si{};
    si.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.waitSemaphoreCount   = 1;
    si.pWaitSemaphores      = &gState.imgAvail;
    si.pWaitDstStageMask    = &waitStage;
    si.commandBufferCount   = 1;
    si.pCommandBuffers      = &cmd;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores    = &gState.renderDone;
    vkQueueSubmit(gState.queue, 1, &si, gState.frameFence);

    VkPresentInfoKHR pi{};
    pi.sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores    = &gState.renderDone;
    pi.swapchainCount     = 1;
    pi.pSwapchains        = &gState.swapchain;
    pi.pImageIndices      = &imgIdx;
    vkQueuePresentKHR(gState.queue, &pi);
}

static void handleCmd(android_app* app, int32_t cmd) {
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            if (app->window) {
                try { initVulkan(app); }
                catch (const std::exception& e) { LOGE("initVulkan failed: %s", e.what()); }
                catch (...) { LOGE("initVulkan failed (unknown exception)"); }
            }
            break;
        case APP_CMD_TERM_WINDOW:
            gState.initialized = false;
            break;
        default: break;
    }
}

void android_main(android_app* app) {
    app->onAppCmd = handleCmd;
    while (true) {
        int events;
        android_poll_source* source;
        while (ALooper_pollOnce(gState.initialized ? 0 : -1, nullptr, &events,
                               reinterpret_cast<void**>(&source)) >= 0) {
            if (source) source->process(app, source);
            if (app->destroyRequested) return;
        }
        drawFrame();
    }
}
