import { cn } from '@/lib/utils'

// Brand mark for Reserva Gol.
// NOTE: space reserved for the official brand file. When available, drop it in
// /public/logo.svg (or .png) and swap the <BrandMark/> for an <img/> here.
export function BrandMark({ className }) {
  return (
    <span
      className={cn(
        'inline-flex items-center justify-center rounded-lg bg-primary text-primary-foreground font-display font-bold',
        className
      )}
    >
      <svg viewBox="0 0 24 24" fill="none" className="h-[62%] w-[62%]" aria-hidden>
        <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8" />
        <path d="M12 7.5l3.2 2.3-1.2 3.8h-4L8.8 9.8 12 7.5z" fill="currentColor" />
        <path d="M12 7.5V4M15.2 9.8l3.1-1M13.8 13.6l1.9 3M10.2 13.6l-1.9 3M8.8 9.8l-3.1-1" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      </svg>
    </span>
  )
}

export function Logo({ className, size = 'md', showText = true }) {
  const s = size === 'sm'
    ? { sym: 'h-7', word: 'h-4' }
    : size === 'lg'
    ? { sym: 'h-11', word: 'h-7' }
    : { sym: 'h-9', word: 'h-5' }
  return (
    <div className={cn('flex items-center gap-2.5', className)}>
      <img src="/reserva-symbol.png" alt="Reserva Gol" className={cn('w-auto select-none object-contain', s.sym)} />
      {showText && (
        <img src="/reserva-wordmark.png" alt="" aria-hidden className={cn('w-auto select-none object-contain', s.word)} />
      )}
    </div>
  )
}
