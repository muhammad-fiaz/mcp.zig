<script setup lang="ts">
import { useData } from "vitepress";
import { computed } from "vue";

const { page } = useData();

const breadcrumbs = computed(() => {
  const path = page.value.relativePath.replace(/\.md$/, "");
  const parts = path.split("/").filter(Boolean);

  const items = [{ label: "Home", href: "/" }];

  let currentPath = "";
  for (let i = 0; i < parts.length; i++) {
    currentPath += `/${parts[i]}`;
    const label = parts[i]
      .split("-")
      .map((s: string) => s.charAt(0).toUpperCase() + s.slice(1))
      .join(" ");

    items.push({
      label,
      href: i === parts.length - 1 ? undefined : currentPath,
    });
  }

  return items;
});
</script>

<template>
  <nav v-if="breadcrumbs.length > 1" class="vp-breadcrumb" aria-label="Breadcrumb">
    <ol>
      <li v-for="(item, index) in breadcrumbs" :key="index">
        <span v-if="index > 0" class="separator">/</span>
        <a v-if="item.href" :href="item.href">{{ item.label }}</a>
        <span v-else class="current">{{ item.label }}</span>
      </li>
    </ol>
  </nav>
</template>

<style scoped>
.vp-breadcrumb ol {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  list-style: none;
  margin: 0;
  padding: 0;
}

.vp-breadcrumb li {
  display: inline-flex;
  align-items: center;
}
</style>
