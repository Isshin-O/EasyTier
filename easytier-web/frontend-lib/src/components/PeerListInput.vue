<script setup lang="ts">
import { Button } from 'primevue'
import { useI18n } from 'vue-i18n'
import UrlInput from './UrlInput.vue'
import type { NetworkPeerConfig } from '../types/network'

const props = withDefaults(defineProps<{
  protos: { [proto: string]: number }
  addLabel: string
  placeholder?: string
  defaultUrl?: string
  allowToggle?: boolean
}>(), {
  allowToggle: true,
})

const peers = defineModel<NetworkPeerConfig[]>({ required: true })
const { t } = useI18n()

function addPeer(): void {
  peers.value.push({
    uri: props.defaultUrl || 'tcp://0.0.0.0:11010',
    enabled: true,
  })
}

function removePeer(index: number): void {
  peers.value.splice(index, 1)
}

function togglePeer(peer: NetworkPeerConfig): void {
  peer.enabled = peer.enabled === false
}
</script>

<template>
  <div class="flex flex-col gap-y-2 w-full">
    <div
      v-for="(peer, index) in peers"
      :key="index"
      class="flex gap-2 items-center w-full"
      :class="{ 'peer-disabled': peer.enabled === false }"
    >
      <UrlInput v-model="peer.uri" :protos="protos" :placeholder="placeholder">
        <template #actions>
          <Button
            :icon="peer.enabled === false ? 'pi pi-eye-slash' : 'pi pi-eye'"
            severity="secondary"
            text
            rounded
            :disabled="props.allowToggle === false"
            :aria-label="t(peer.enabled === false ? 'enable_initial_node' : 'disable_initial_node')"
            :title="t(props.allowToggle === false
              ? 'initial_node_toggle_requires_upgrade'
              : (peer.enabled === false ? 'enable_initial_node' : 'disable_initial_node'))"
            @click="togglePeer(peer)"
          />
          <Button
            icon="pi pi-trash"
            severity="danger"
            text
            rounded
            :aria-label="t('delete_initial_node')"
            :title="t('delete_initial_node')"
            @click="removePeer(index)"
          />
        </template>
      </UrlInput>
    </div>
    <div
      data-stub="add-peer"
      class="flex justify-center items-center w-full h-10 border-2 border-dashed border-surface-300 dark:border-surface-600 rounded-lg cursor-pointer hover:border-primary hover:bg-surface-50 dark:hover:bg-surface-800 transition-colors duration-200 gap-2 text-surface-500 dark:text-surface-400"
      @click="addPeer"
    >
      <i class="pi pi-plus text-sm"></i>
      <span class="text-sm font-medium">{{ addLabel }}</span>
    </div>
  </div>
</template>

<style scoped>
.peer-disabled {
  opacity: 0.55;
}
</style>
