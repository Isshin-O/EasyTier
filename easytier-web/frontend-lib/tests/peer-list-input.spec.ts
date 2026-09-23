import { mount } from '@vue/test-utils'
import { defineComponent, h, ref } from 'vue'
import { describe, expect, it, vi } from 'vitest'
import PeerListInput from '../src/components/PeerListInput.vue'

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key: string) => key,
  }),
}))

const UrlInputStub = defineComponent({
  name: 'UrlInput',
  props: {
    modelValue: String,
  },
  emits: ['update:modelValue'],
  setup(props, { slots }) {
    return () => h('div', { 'data-stub': 'url-input', 'data-url': props.modelValue }, slots.actions?.())
  },
})

const ButtonStub = defineComponent({
  name: 'Button',
  props: {
    icon: String,
    ariaLabel: String,
  },
  emits: ['click'],
  setup(props, { emit }) {
    return () => h('button', {
      type: 'button',
      'data-icon': props.icon,
      'aria-label': props.ariaLabel,
      onClick: () => emit('click'),
    })
  },
})

function mountPeerList() {
  const peers = ref([
    { uri: 'tcp://active:11010', enabled: true },
    { uri: 'udp://paused:11010', enabled: false },
  ])
  const Host = defineComponent({
    setup() {
      return () => h(PeerListInput, {
        modelValue: peers.value,
        'onUpdate:modelValue': (value: typeof peers.value) => { peers.value = value },
        protos: { tcp: 11010, udp: 11010 },
        addLabel: 'Add',
        defaultUrl: 'tcp://:11010',
      })
    },
  })
  const wrapper = mount(Host, {
    global: {
      stubs: {
        Button: ButtonStub,
        UrlInput: UrlInputStub,
      },
    },
  })
  return { peers, wrapper }
}

describe('PeerListInput', () => {
  it('toggles a peer without removing its row', async () => {
    const { peers, wrapper } = mountPeerList()
    const toggleButtons = wrapper.findAll('button[data-icon="pi pi-eye"], button[data-icon="pi pi-eye-slash"]')

    await toggleButtons[0].trigger('click')
    expect(peers.value).toHaveLength(2)
    expect(peers.value[0].enabled).toBe(false)
    expect(wrapper.findAll('.peer-disabled')).toHaveLength(2)

    await wrapper.find('button[data-icon="pi pi-eye-slash"]').trigger('click')
    expect(peers.value[0].enabled).toBe(true)
  })

  it('deletes and adds rows independently of the enable toggle', async () => {
    const { peers, wrapper } = mountPeerList()

    await wrapper.find('button[data-icon="pi pi-trash"]').trigger('click')
    expect(peers.value).toHaveLength(1)

    await wrapper.find('[data-stub="add-peer"]').trigger('click')
    expect(peers.value).toHaveLength(2)
    expect(peers.value[1]).toEqual({ uri: 'tcp://:11010', enabled: true })
  })
})
