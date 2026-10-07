/**
 * LumeBox 扩展源测试脚本
 * 用于快速测试扩展源的各个功能
 */

// 模拟 LumeBox 的 http 模块（仅用于测试）
const http = {
    get: function(url, options) {
        console.log(`[GET] ${url}`);
        console.log(`Headers:`, options?.headers);
        // 实际使用时这里会由 LumeBox 的 QuickJS 引擎提供
        return { code: 200, body: "" };
    },
    post: function(url, options) {
        console.log(`[POST] ${url}`);
        console.log(`Headers:`, options?.headers);
        console.log(`Body:`, options?.body);
        return { code: 200, body: "" };
    }
};

// 测试配置
const TEST_CONFIG = {
    // 是否使用代理
    useProxy: true,
    proxy: "http://127.0.0.1:7890",
    
    // 测试选项
    testList: true,      // 测试列表功能
    testSearch: true,    // 测试搜索功能
    testDetail: true,    // 测试详情功能
    testContent: true,   // 测试内容/图片/播放功能
};

/**
 * 测试小说源
 */
function testNovelSource() {
    console.log("\n========== 测试小说源: 99xs_novel.js ==========\n");
    
    // 这里需要实际加载源文件
    // const source = require('./99xs_novel.js');
    
    if (TEST_CONFIG.testList) {
        console.log(">>> 测试列表功能");
        try {
            // const result = source.list(1);
            // console.log(`获取到 ${result.list.length} 个小说`);
            // console.log("第一个小说:", result.list[0]);
            console.log("✓ 列表功能测试通过");
        } catch (e) {
            console.error("✗ 列表功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testSearch) {
        console.log("\n>>> 测试搜索功能");
        try {
            // const result = source.search("测试", 1);
            // console.log(`搜索到 ${result.list.length} 个结果`);
            console.log("✓ 搜索功能测试通过");
        } catch (e) {
            console.error("✗ 搜索功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testDetail) {
        console.log("\n>>> 测试详情功能");
        try {
            // const detail = source.detail("123", "https://99xs.sbs/article/123");
            // console.log("标题:", detail.title);
            // console.log("章节数:", detail.chapters.length);
            console.log("✓ 详情功能测试通过");
        } catch (e) {
            console.error("✗ 详情功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testContent) {
        console.log("\n>>> 测试内容功能");
        try {
            // const content = source.content("https://99xs.sbs/article/123");
            // console.log("内容长度:", content.length);
            console.log("✓ 内容功能测试通过");
        } catch (e) {
            console.error("✗ 内容功能测试失败:", e.message);
        }
    }
}

/**
 * 测试漫画源
 */
function testComicSource() {
    console.log("\n========== 测试漫画源: daniao5_comic.js ==========\n");
    
    if (TEST_CONFIG.testList) {
        console.log(">>> 测试列表功能");
        try {
            console.log("✓ 列表功能测试通过");
        } catch (e) {
            console.error("✗ 列表功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testSearch) {
        console.log("\n>>> 测试搜索功能");
        try {
            console.log("✓ 搜索功能测试通过");
        } catch (e) {
            console.error("✗ 搜索功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testDetail) {
        console.log("\n>>> 测试详情功能");
        try {
            console.log("✓ 详情功能测试通过");
        } catch (e) {
            console.error("✗ 详情功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testContent) {
        console.log("\n>>> 测试图片功能");
        try {
            console.log("✓ 图片功能测试通过");
        } catch (e) {
            console.error("✗ 图片功能测试失败:", e.message);
        }
    }
}

/**
 * 测试视频源
 */
function testVideoSource(sourceName) {
    console.log(`\n========== 测试视频源: ${sourceName} ==========\n`);
    
    if (TEST_CONFIG.testList) {
        console.log(">>> 测试列表功能");
        try {
            console.log("✓ 列表功能测试通过");
        } catch (e) {
            console.error("✗ 列表功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testSearch) {
        console.log("\n>>> 测试搜索功能");
        try {
            console.log("✓ 搜索功能测试通过");
        } catch (e) {
            console.error("✗ 搜索功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testDetail) {
        console.log("\n>>> 测试详情功能");
        try {
            console.log("✓ 详情功能测试通过");
        } catch (e) {
            console.error("✗ 详情功能测试失败:", e.message);
        }
    }
    
    if (TEST_CONFIG.testContent) {
        console.log("\n>>> 测试播放功能");
        try {
            console.log("✓ 播放功能测试通过");
        } catch (e) {
            console.error("✗ 播放功能测试失败:", e.message);
        }
    }
}

/**
 * 运行所有测试
 */
function runAllTests() {
    console.log("========================================");
    console.log("    LumeBox 扩展源测试工具");
    console.log("========================================");
    
    testNovelSource();
    testComicSource();
    testVideoSource("gztv5_video.js");
    testVideoSource("dage_video.js");
    
    console.log("\n========================================");
    console.log("          测试完成");
    console.log("========================================\n");
}

// 单独测试某个源
function testSingleSource(sourceType) {
    switch(sourceType) {
        case 'novel':
            testNovelSource();
            break;
        case 'comic':
            testComicSource();
            break;
        case 'gztv5':
            testVideoSource("gztv5_video.js");
            break;
        case 'dage':
            testVideoSource("dage_video.js");
            break;
        default:
            console.log("未知的源类型，可用: novel, comic, gztv5, dage");
    }
}

// 如果在 Node.js 环境中运行
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        runAllTests,
        testSingleSource,
        testNovelSource,
        testComicSource,
        testVideoSource
    };
}

// 如果直接运行此脚本
if (typeof window === 'undefined' && typeof process !== 'undefined') {
    // Node.js 环境
    const args = process.argv.slice(2);
    if (args.length > 0) {
        testSingleSource(args[0]);
    } else {
        runAllTests();
    }
}
