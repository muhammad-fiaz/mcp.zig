// https://vitepress.dev/guide/custom-theme
import DefaultTheme from "vitepress/theme";
import Breadcrumbs from "./components/Breadcrumbs.vue";
import "./custom.css";

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component("Breadcrumbs", Breadcrumbs);
  },
};
