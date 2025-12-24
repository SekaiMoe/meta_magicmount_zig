# Meta Magic WebUI - Next.js 版本

基于 Next.js 14 构建的现代化 Web 用户界面，支持响应式设计、主题切换和配置管理。

## 🚀 技术栈

- **框架**: Next.js 14 (App Router)
- **语言**: TypeScript
- **样式**: Tailwind CSS
- **组件**: React 18
- **包管理**: Yarn

## ✨ 功能特性

- 📱 **响应式设计** - 完美适配桌面端和移动端
- 🌙 **主题切换** - 支持浅色、深色和系统主题
- ⚙️ **配置管理** - 灵活的配置系统
- 🎨 **现代化UI** - 基于 Tailwind CSS 的美观界面
- ⚡ **高性能** - Next.js 提供的优化和快速加载

## 🛠️ 开发

### 安装依赖
```bash
yarn install
```

### 启动开发服务器
```bash
yarn dev
```

在浏览器中打开 [http://localhost:3000](http://localhost:3000) 查看结果。

### 构建生产版本
```bash
yarn build
yarn start
```

### 代码检查
```bash
yarn lint
```

## 📁 项目结构

```
src/
├── app/                    # Next.js App Router
│   ├── globals.css        # 全局样式
│   ├── layout.tsx         # 根布局
│   └── page.tsx          # 首页
├── components/            # React 组件
│   └── ConfigView.tsx    # 配置视图组件
└── ...
```

## 🎯 主要组件

### ConfigView
一个模态配置组件，支持：
- 主题设置（系统/浅色/深色）
- 语言选择
- 通知开关
- 自动保存设置

### 主页面
- 欢迎界面
- 功能特性展示
- 主题切换按钮
- 响应式布局

## 🎨 样式系统

- **Tailwind CSS**: 实用优先的 CSS 框架
- **自定义滚动条**: 美观的滚动条样式
- **动画效果**: 淡入、滑动等过渡动画
- **深色模式**: 完整的深色主题支持
- **响应式**: 移动端优先的设计

## 📝 开发说明

1. 所有组件都使用 TypeScript 确保类型安全
2. 使用 'use client' 指令确保客户端渲染
3. 主题设置保存在 localStorage 中
4. 遵循 Next.js App Router 的最佳实践

## 🔧 配置

项目使用以下配置文件：
- `next.config.ts` - Next.js 配置
- `tailwind.config.ts` - Tailwind CSS 配置
- `tsconfig.json` - TypeScript 配置
- `eslint.config.mjs` - ESLint 配置

## 📄 许可证

MIT License